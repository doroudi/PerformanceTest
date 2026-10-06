<#
.SYNOPSIS
    Runs one k6 performance test against the API deployed in Kubernetes, and keeps
    the evidence.

.DESCRIPTION
    Deploy (or reuse) the API, run a single k6 scenario as a Kubernetes Job in the
    same cluster, then write the run's output to results/<timestamp>-<type>/:

        k6.log        full container log, including the human summary
        summary.json  machine-readable summary (schema perftest.summary/v1)
        meta.json     what was run, against which image, with which knobs
        k6-job.yaml   the exact Job manifest that was applied

    It exists to remove the ways the previous runner could mislead you:

      * it waits for the Job to finish OR fail, and surfaces k6's own exit code
        (k6 exits 99 when thresholds are crossed) instead of blocking for the full
        timeout on a Job that already failed;
      * TARGET_URL is mandatory and validated, because the old default silently
        pointed at a Swagger UI page;
      * every run setting is recorded and archived, so a result can be explained
        afterwards;
      * the k6 pod asks for real CPU and prefers a different node from the API, so
        the generator does not quietly become the bottleneck being measured.

.PARAMETER TargetUrl
    The endpoint to exercise, reachable from inside the cluster, e.g.
    http://api-service:8080/api/orders. Required: this kit defines no default
    target so a misconfigured run fails loudly instead of measuring something else.

.PARAMETER TestType
    smoke | load | stress | soak | spike (whichever scenarios exist in k6/scripts).

.PARAMETER Image
    API image reference including a tag or digest. Tag it per build (git SHA, build
    number) rather than reusing one tag: a reused tag can be served from a node's
    image cache, which means you measure the previous build.

.PARAMETER Dockerfile
    Optional. The Dockerfile to build the API image from, together with -BuildContext.
    Prefer this over -ApiPath: a Dockerfile is meaningless without its context, and
    this makes the context something you state instead of something the runner guesses.

    The context defaults to the Dockerfile's own directory, which is the only default
    that can work for a self-contained Dockerfile (a COPY can never reach above its
    context). A Dockerfile that copies from the repository root - a `COPY
    ["nuget.config", "."]` into a private feed, say - needs -BuildContext explicitly,
    and the runner warns by name when a COPY source is not in the context it was given.

.PARAMETER BuildContext
    Optional. The directory to build from. Defaults to the Dockerfile's directory.

.PARAMETER BuildArg
    Optional. --build-arg values as NAME=value, repeatable. The one this kit's own
    k8s/app/Dockerfile needs is APP_DLL, since that image starts whichever assembly you
    name rather than hard-coding one.

.PARAMETER CredentialsSecret
    Optional. The name of a Kubernetes Secret in the target namespace whose keys are
    injected into the k6 Job as environment variables (envFrom). Use it for the journey
    and authenticated scenarios: -EnvVars values are written verbatim into the archived
    Job manifest (results/<run>/k6-job.yaml), so a password passed that way is a
    password in an artefact that gets attached to tickets. A Secret keeps it out of the
    manifest entirely, and its keys are not recorded either - only its name.

.PARAMETER ResolveHost
    Optional, repeatable. Hostnames to resolve on the machine running this script and pin
    into the k6 Job's /etc/hosts as hostAliases.

    This exists because a cluster's DNS often cannot resolve external names, and an
    authenticated scenario cannot start without reaching its identity provider. Measured
    on a real minikube: a k6 pod asking for the IdP got `lookup <host> on 10.96.0.10:53:
    server misbehaving` while CoreDNS logged `read udp ...->192.168.65.254:53: i/o
    timeout`, and the same name resolved from the host. Resolving where DNS works and
    pinning the address removes the cluster resolver from the path for this run.

    The mapping is recorded in meta.json as `host_aliases`: a result that reached a
    pinned address is a result about that address. A name that cannot be resolved here
    warns and is skipped rather than failing the run.

.PARAMETER Preflight
    Run a 1-VU smoke test as its own Job first, and refuse to start the real test when
    NOT ONE request succeeded. A twelve-minute load test that is 100% connection
    failures - or 100% 401s because the credentials never reached the pod - is the most
    expensive possible way to learn that the target does not answer from inside the
    cluster. Skipped for the smoke type itself, where the preflight is the test.

    The preflight log is archived as results/<run>/preflight.log.

.PARAMETER ApiPath
    Optional. Shorthand for "the API project's own Dockerfile": builds <ApiPath>/Dockerfile
    with the context guessed three directories up, which is another repository's layout.
    Kept for existing callers and scheduled for removal - prefer -Image, or -Dockerfile
    with -BuildContext.

.PARAMETER EnvVars
    Scenario knobs in NAME=value form, e.g. -EnvVars TARGET_VUS=200,HOLD_DURATION=30m.

.EXAMPLE
    ./scripts/deploy-and-test.ps1 http://api-service:8080/api/health smoke

.EXAMPLE
    # Build from an explicit Dockerfile and context, deploy, then stress test.
    ./scripts/deploy-and-test.ps1 -TargetUrl http://api-service:8080/api/orders `
        -TestType stress -Image service-api:local `
        -Dockerfile ./deploy/Dockerfile -BuildContext . `
        -MemoryRequest 4Gi -MemoryLimit 4Gi -CpuRequest 2 -CpuLimit 2

.EXAMPLE
    # The publish-output image this kit ships (k8s/app/Dockerfile), with a preflight.
    ./scripts/deploy-and-test.ps1 -TargetUrl http://api-service:8080/healthz `
        -TestType load -Image finance-api:local `
        -Dockerfile k8s/app/Dockerfile -BuildContext .build/finance-api `
        -BuildArg APP_DLL=ExchangePortal.Finance.Api.dll `
        -CredentialsSecret perf-test-credentials -Preflight

.EXAMPLE
    ./scripts/deploy-and-test.ps1 -TargetUrl http://api-service:8080/api/orders `
        -TestType load -Image service-api:$(git rev-parse --short HEAD) `
        -EnvVars TARGET_VUS=200,HOLD_DURATION=15m -DeleteJobAfterRun
#>
[CmdletBinding()]
param(
    # Required unless -DeployOnly. Validated at runtime so that a deploy-only run
    # does not have to name a target URL it will not use.
    [Parameter(Position = 0)]
    [string] $TargetUrl,

    [Parameter(Position = 1)]
    [string] $TestType,

    [string] $Image = 'service-api:local',
    [string] $K6Image = 'k6-custom:local',

    [string] $Namespace = 'perf-test',
    [string] $RuntimeEnvironment = 'Production',

    [ValidateSet('IfNotPresent', 'Always', 'Never')]
    [string] $ImagePullPolicy = 'IfNotPresent',

    [int] $Replicas = 1,

    # Generous on purpose: a CPU-starved k6 reports the SUT as slow when the
    # generator is what ran out of CPU. Lower it only to fit a small cluster, and
    # treat the results as suspect if you do.
    [string] $K6CpuRequest = '1',

    # ---------------------------------------------------------------------
    # The API container's CPU and memory. These are as much "the experiment" as
    # the load profile is: "the app sustains X rps at p95 < Y" means nothing
    # without the resources it was allowed. Two runs with different values are
    # two different experiments, which is why they are recorded in meta.json.
    #
    # CPU limit in particular is the single most useful knob here, because a
    # .NET app at its CPU limit throttles rather than queueing: that shows up as
    # a latency cliff and as container_cpu_cfs_throttled_periods_total climbing
    # on the pod dashboard.
    # ---------------------------------------------------------------------
    [string] $CpuRequest = '250m',
    [string] $CpuLimit = '500m',
    [string] $MemoryRequest = '256Mi',
    [string] $MemoryLimit = '512Mi',

    # Environment variables for the APPLICATION container, NAME=value, parsed the
    # same way as -EnvVars. Deliberately separate from -EnvVars, which goes to the
    # generator: one bag for both is how an application setting silently becomes a
    # scenario knob (or the reverse) and nobody notices.
    [string[]] $AppEnvVars = @(),

    # Remote-write endpoint for the generator's metrics, e.g.
    # http://prometheus.perf-observability.svc.cluster.local:9090/api/v1/write
    # Empty means the Job exports nothing and only the artefacts are produced.
    [string] $PrometheusWriteUrl = '',

    # A Secret in the target namespace whose keys become environment variables on the
    # k6 Job. Keeps credentials out of the archived Job manifest; see .PARAMETER above.
    [string] $CredentialsSecret = '',

    # Hostnames to resolve on THIS machine and pin into the k6 Job's /etc/hosts. Names an
    # authenticated scenario has to reach - the identity provider above all - may not be
    # resolvable from inside the cluster at all; see .PARAMETER ResolveHost.
    [string[]] $ResolveHost = @(),

    # Prove the target answers from inside the cluster before running the real profile.
    [switch] $Preflight,

    [int] $TimeoutSeconds = 1800,
    [string[]] $EnvVars = @(),

    [string] $ApiPath,
    [string] $BuildEnv = 'Release',

    # Building the image: an explicit Dockerfile and context (preferred), or the
    # -ApiPath shorthand above.
    [string] $Dockerfile,
    [string] $BuildContext,
    [string[]] $BuildArg = @(),

    [string] $ResultsRoot,

    [switch] $DeployOnly,
    [switch] $TestOnly,
    [switch] $DeleteJobAfterRun,

    # Re-parse an already-collected log, without touching a cluster.
    [string] $FromLog,

    # Write the Job manifest that would be applied, then exit. Needs no cluster:
    # useful for reviewing a change to the runner in a pull request, and for
    # checking the manifest in CI before anything is deployed.
    [string] $EmitJobManifest
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\PerfTest.psm1') -Force

$repoRoot = Get-PerfTestRepoRoot
$scenariosDirectory = Join-Path $repoRoot 'k6\scripts'
$resultsRoot = if ($ResultsRoot) { $ResultsRoot } else { Join-Path $repoRoot 'results' }

$scenarioFile = $null
if ($DeployOnly) {
    if ($TestType) {
        $scenarioFile = Split-Path -Leaf (Resolve-PerfTestScenario -TestType $TestType -ScenariosDirectory $scenariosDirectory)
    }
}
else {
    if (-not $TestType) {
        throw ("-TestType is required. Available test types: {0}." -f ((Get-PerfTestTypes -ScenariosDirectory $scenariosDirectory) -join ', '))
    }
    if (-not $TargetUrl) {
        throw '-TargetUrl is required (the endpoint to exercise, reachable from inside the cluster).'
    }
    $scenarioFile = Split-Path -Leaf (Resolve-PerfTestScenario -TestType $TestType -ScenariosDirectory $scenariosDirectory)
}

function Invoke-Checked {
    param(
        [Parameter(Mandatory = $true)][string] $Command,
        [Parameter(Mandatory = $true)][string[]] $Arguments
    )

    if (-not (Get-Command $Command -ErrorAction SilentlyContinue)) {
        throw "'$Command' was not found on PATH."
    }

    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $Command @Arguments
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previous
    }

    if ($exitCode -ne 0) {
        throw "$Command $($Arguments -join ' ') failed with exit code $exitCode."
    }
}

function Write-PerfTestResult {
    <#
    Shared tail: turn a k6 log into summary.json + meta.json and print the human
    summary that k6 wrote before the JSON block.
    #>
    param(
        [Parameter(Mandatory = $true)][string] $LogPath,
        [Parameter(Mandatory = $true)][string] $SummaryPath,
        [Parameter(Mandatory = $true)][string] $MetaPath,
        [Parameter(Mandatory = $true)][string] $RunDirectory,
        [Parameter(Mandatory = $true)][hashtable] $Metadata,
        [int] $ExitCode = 0,
        [string] $ExitReason = '',
        [string] $JobOutcome = 'unknown'
    )

    $logText = Get-Content -Path $LogPath -Raw
    $rawJson = Get-K6SummaryJsonFromText -Text $logText

    Write-Utf8NoBom -Path $SummaryPath -Content $rawJson | Out-Null
    $summary = $rawJson | ConvertFrom-Json

    $markers = Get-PerfTestSummaryMarkers
    $humanEnd = $logText.IndexOf($markers.Begin)
    $human = if ($humanEnd -gt 0) { $logText.Substring(0, $humanEnd) } else { $logText }
    Write-Host $human.TrimEnd()

    $Metadata['k6_exit_code'] = $ExitCode
    $Metadata['k6_exit_reason'] = $ExitReason
    $Metadata['job_outcome'] = $JobOutcome
    $Metadata['thresholds_all_ok'] = $summary.thresholds_all_ok
    $Metadata['failed_thresholds'] = @($summary.failed_thresholds)
    $Metadata['finished_at'] = (Get-Date).ToUniversalTime().ToString('o')
    Write-PerfTestMetadata -Path $MetaPath -Data $Metadata | Out-Null

    Write-Host ''
    Write-Host 'Run artefacts:' -ForegroundColor Cyan
    Write-Host "  run       : $RunDirectory"
    Write-Host "  log       : $LogPath"
    Write-Host "  summary   : $SummaryPath"
    Write-Host "  metadata  : $MetaPath"
    if ($Metadata['testid']) {
        Write-Host "  testid    : $($Metadata['testid'])  (filter Grafana panels with this)"
    }

    if ($ExitCode -eq 99) {
        Write-Host ''
        Write-Warning 'k6 exit code 99: one or more thresholds were crossed (see the thresholds block above).'
    }

    return $summary
}

function Split-PerfTestImage {
    <# Split an image reference into name + tag/digest, and insist on one of them. #>
    param([Parameter(Mandatory = $true)][string] $Reference)

    if ($Reference -match '@(?<digest>sha256:[0-9a-fA-F]{64})$') {
        return [pscustomobject]@{
            Name   = $Reference.Substring(0, $Reference.IndexOf('@'))
            Tag    = $null
            Digest = $Matches['digest']
        }
    }

    $lastColon = $Reference.LastIndexOf(':')
    $lastSlash = $Reference.LastIndexOf('/')
    if ($lastColon -gt $lastSlash -and $lastColon -gt 0) {
        return [pscustomobject]@{
            Name   = $Reference.Substring(0, $lastColon)
            Tag    = $Reference.Substring($lastColon + 1)
            Digest = $null
        }
    }

    throw "Image '$Reference' has no tag or digest. Use e.g. my-api:1.4.2 or my-api@sha256:<64 hex chars>, so a run can be traced back to an exact build."
}

function New-PerfTestOverlay {
    <#
    Generate the kustomize overlay for this run.

    The old runner applied the checked-in manifests and then patched them with
    strategic-merge patches. That is how the Service ended up advertising a port 80
    route with nothing behind it, and how the container's port and environment
    drifted away from the YAML. Generating the overlay keeps every per-run setting
    in one file that is also archived alongside the results.
    #>
    param(
        [Parameter(Mandatory = $true)][string] $OverlayDirectory,
        [Parameter(Mandatory = $true)][string] $NamespaceName,
        [Parameter(Mandatory = $true)][string] $ImageReference,
        [Parameter(Mandatory = $true)][string] $PullPolicy,
        [Parameter(Mandatory = $true)][int] $ReplicaCount,
        [Parameter(Mandatory = $true)][string] $Environment,
        [Parameter(Mandatory = $true)][string] $CpuRequest,
        [Parameter(Mandatory = $true)][string] $CpuLimit,
        [Parameter(Mandatory = $true)][string] $MemoryRequest,
        [Parameter(Mandatory = $true)][string] $MemoryLimit,
        [hashtable] $AppEnvironment = @{}
    )

    # Validated, then deliberately NOT used to build the overlay's `images:` entry.
    #
    # The old overlay set the image with kustomize's images: transformer, naming
    # `your-aspnet-api` - a name no manifest ever had. The transformer matches on the
    # image NAME, so it matched nothing, substituted nothing, and the runner deployed
    # k8s/base's placeholder `your-api:latest` instead. The only visible symptom was a
    # pod stuck in ImagePullBackOff and a rollout status that timed out 300s later with
    # no mention of the image, while the Deployment was quietly rewritten to point at a
    # repository that does not exist.
    #
    # The image is therefore set by the same strategic-merge patch that sets the
    # resources, the environment and the pull policy: one mechanism, matched on the
    # container name that IS in the base manifest, and visible in the overlay that gets
    # archived next to the results.
    $null = Split-PerfTestImage -Reference $ImageReference

    $kustomization = @(
        'apiVersion: kustomize.config.k8s.io/v1beta1'
        'kind: Kustomization'
        ''
        "namespace: $NamespaceName"
        ''
        'resources:'
        '  - ../../base'
        '  - namespace.yaml'
        ''
        'patches:'
        '  - path: runtime-settings.yaml'
        ''
    )

    $namespaceManifest = @(
        'apiVersion: v1'
        'kind: Namespace'
        'metadata:'
        "  name: $NamespaceName"
        '  labels:'
        '    app.kubernetes.io/part-of: perf-test-kit'
        ''
    )

    $runtimeSettings = @(
        'apiVersion: apps/v1'
        'kind: Deployment'
        'metadata:'
        '  name: api-deployment'
        'spec:'
        "  replicas: $ReplicaCount"
        '  template:'
        '    spec:'
        '      containers:'
        '        - name: api'
        # Quoted: a bare tag that looks like a number (CI build numbers) is parsed as an
        # integer by YAML and rejected by the API server, and a digest reference contains
        # a colon. Both are perfectly legal image references.
        "          image: `"$ImageReference`""
        "          imagePullPolicy: $PullPolicy"
        '          env:'
        '            - name: ASPNETCORE_ENVIRONMENT'
        "              value: `"$Environment`""
    )
    foreach ($name in ($AppEnvironment.Keys | Sort-Object)) {
        $runtimeSettings += "            - name: $name"
        $runtimeSettings += "              value: `"$($AppEnvironment[$name])`""
    }
    $runtimeSettings += @(
        '          resources:'
        '            requests:'
        "              cpu: `"$CpuRequest`""
        "              memory: `"$MemoryRequest`""
        '            limits:'
        # No memory headroom trickery here, and the CPU limit is emitted even when
        # it equals the request: a .NET app that is CPU-limited throttles, and
        # seeing that in Prometheus is the point of the exercise.
        "              cpu: `"$CpuLimit`""
        "              memory: `"$MemoryLimit`""
        ''
    )

    Write-Utf8NoBom -Path (Join-Path $OverlayDirectory 'kustomization.yaml') -Content ($kustomization -join "`n") | Out-Null
    Write-Utf8NoBom -Path (Join-Path $OverlayDirectory 'namespace.yaml') -Content ($namespaceManifest -join "`n") | Out-Null
    Write-Utf8NoBom -Path (Join-Path $OverlayDirectory 'runtime-settings.yaml') -Content ($runtimeSettings -join "`n") | Out-Null

    return $OverlayDirectory
}

function New-K6JobManifest {
    <# Write the Job manifest for this run; it is archived next to the results. #>
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $JobName,
        [Parameter(Mandatory = $true)][string] $NamespaceName,
        [Parameter(Mandatory = $true)][string] $Type,
        [Parameter(Mandatory = $true)][string] $Script,
        [Parameter(Mandatory = $true)][string] $Url,
        [Parameter(Mandatory = $true)][string] $GeneratorImage,
        [Parameter(Mandatory = $true)][string] $PullPolicy,
        [Parameter(Mandatory = $true)][string] $CpuRequest,
        [Parameter(Mandatory = $true)][hashtable] $ScenarioEnv,
        [string] $PrometheusWriteUrl = '',
        [string] $TestId = '',
        [string] $CredentialsSecret = '',
        [hashtable] $HostAliases = @{}
    )

    $envLines = @(
        '            - name: TARGET_URL'
        "              value: `"$Url`""
    )
    foreach ($name in ($ScenarioEnv.Keys | Sort-Object)) {
        $envLines += "            - name: $name"
        $envLines += "              value: `"$($ScenarioEnv[$name])`""
    }

    # Credentials arrive as a Secret rather than as env entries above, because this
    # manifest is archived verbatim next to the results: anything written here is an
    # artefact, and an artefact containing a password gets attached to tickets and
    # pasted into chat. envFrom is listed AFTER env so that an explicit env entry
    # (TARGET_URL, say) still wins over a same-named key in the Secret.
    $secretLines = @()
    if ($CredentialsSecret) {
        $secretLines = @(
            '          envFrom:'
            '            - secretRef:'
            "                name: $CredentialsSecret"
        )
    }

    # Addresses the RUNNER resolved, pinned into the pod's /etc/hosts. The generator then
    # never asks the cluster's resolver for them, which is what makes an authenticated
    # scenario possible on a cluster whose DNS cannot reach external names - and it is
    # recorded in meta.json, because "which address was this run talking to" is part of
    # what the result means.
    $hostAliasLines = @()
    if ($HostAliases -and $HostAliases.Count -gt 0) {
        $hostAliasLines = @(
            '      # Resolved on the host that started this run, not by the cluster resolver:',
            '      # an identity provider that cannot be resolved in-cluster fails every',
            '      # authenticated request before it is even sent.',
            '      hostAliases:'
        )
        foreach ($aliasHost in ($HostAliases.Keys | Sort-Object)) {
            $hostAliasLines += "        - ip: `"$($HostAliases[$aliasHost])`""
            $hostAliasLines += '          hostnames:'
            $hostAliasLines += "            - `"$aliasHost`""
        }
    }

    # Metric export. K6_OUT is what enables an output at all - the remote-write URL
    # on its own sends nothing, and the run then succeeds while writing no metrics.
    # Native histograms are requested so the dashboard can compute true
    # per-interval percentiles rather than k6's cumulative gauge statistics.
    if ($PrometheusWriteUrl) {
        $envLines += @(
            '            - name: K6_OUT'
            '              value: "experimental-prometheus-rw"'
            '            - name: K6_PROMETHEUS_RW_SERVER_URL'
            "              value: `"$PrometheusWriteUrl`""
            '            - name: K6_PROMETHEUS_RW_TREND_AS_NATIVE_HISTOGRAM'
            '              value: "true"'
            '            - name: K6_PROMETHEUS_RW_PUSH_INTERVAL'
            '              value: "2s"'
        )
    }

    $manifest = @(
        'apiVersion: batch/v1'
        'kind: Job'
        'metadata:'
        "  name: $JobName"
        "  namespace: $NamespaceName"
        '  labels:'
        '    app: k6'
        "    perf-test-kit/test-type: $Type"
        'spec:'
        '  # Never retry: a retried load test doubles the load on the target and',
        '  # corrupts the measurement.',
        '  backoffLimit: 0'
        '  # Keep the finished Job (and its logs) for a week, then let the cluster',
        '  # clean it up. The artefacts this script writes are the durable copy.',
        '  ttlSecondsAfterFinished: 604800'
        '  template:'
        '    metadata:'
        '      labels:'
        '        app: k6'
        "        perf-test-kit/test-type: $Type"
        '    spec:'
        '      restartPolicy: Never'
        '      # Prefer a node without the API on it. On a single-node cluster this',
        '      # is ignored and the generator competes with the target for CPU -',
        '      # which is exactly the situation where the numbers must not be trusted.',
        '      affinity:'
        '        podAntiAffinity:'
        '          preferredDuringSchedulingIgnoredDuringExecution:'
        '            - weight: 100'
        '              podAffinityTerm:'
        '                topologyKey: kubernetes.io/hostname'
        '                labelSelector:'
        '                  matchLabels:'
        '                    app: api'
    ) + $hostAliasLines + @(
        '      containers:'
        '        - name: k6'
        "          image: $GeneratorImage"
        "          imagePullPolicy: $PullPolicy"
        # --tag test_type is set here rather than in the scenario's options.tags:
        # measured on the compose stack, a tag set inside options.tags does not
        # reach a metrics backend, while the same tag passed on the CLI does.
        #
        # --tag testid labels this run's series so the Grafana dashboard's run
        # selector and PromQL can be filtered to one run. It is the same value as the
        # results directory name, so an artefact and the series that produced it name
        # each other - which is what the compose runner has always done.
        $tagArguments = '          command: ["k6", "run", "--tag", "test_type=' + $TestType + '"'
        if ($TestId) {
            $tagArguments += ', "--tag", "testid=' + $TestId + '"'
        }
        $tagArguments += ', "/scripts/' + $Script + '"]'
        $tagArguments
        '          env:'
    ) + $envLines + $secretLines + @(
        '          resources:'
        '            requests:'
        "              cpu: `"$CpuRequest`""
        '              memory: "512Mi"'
        '            limits:'
        '              # Deliberately no CPU limit: a CPU-throttled k6 reports the',
        '              # target as slow while the generator is the real bottleneck.',
        '              # Memory is capped so a leaking scenario cannot take a node down.',
        '              memory: "1Gi"'
        ''
    )

    Write-Utf8NoBom -Path $Path -Content ($manifest -join "`n") | Out-Null
    return $Path
}

function Test-PerfTestDockerContext {
    <#
    Report COPY/ADD sources that a Dockerfile names but the build context does not
    contain.

    Best effort, and it warns rather than throws: a Dockerfile may legitimately use
    build args, URLs, multi-stage copies and globs, and a false alarm must never stop a
    build that would have worked. Docker's own failure for this case - "failed to
    compute cache key: ... not found" - never says that the CONTEXT is what is wrong,
    which is the whole reason this exists.
    #>
    param(
        [Parameter(Mandatory = $true)][string] $Dockerfile,
        [Parameter(Mandatory = $true)][string] $BuildContext
    )

    $warnings = @()

    $lines = @(Get-Content -Path $Dockerfile -ErrorAction SilentlyContinue)
    if ($lines.Count -eq 0) { return , $warnings }

    # Join line continuations first. A COPY broken over three lines with trailing
    # backslashes is ONE instruction, and reading this file line by line would miss it -
    # which is exactly the shape a multi-source COPY usually takes.
    $logicalLines = @()
    $buffer = ''
    foreach ($line in $lines) {
        $trimmed = $line.TrimEnd()
        if ($trimmed.Trim().StartsWith('#')) { continue }
        if ($trimmed.EndsWith('\')) {
            $buffer += $trimmed.Substring(0, $trimmed.Length - 1) + ' '
            continue
        }
        $logicalLines += ($buffer + $trimmed)
        $buffer = ''
    }
    if ($buffer) { $logicalLines += $buffer }

    foreach ($instruction in $logicalLines) {
        $match = [regex]::Match($instruction, '^\s*(?<verb>COPY|ADD)\s+(?<rest>.+?)\s*$', 'IgnoreCase')
        if (-not $match.Success) { continue }

        $rest = $match.Groups['rest'].Value

        # --from=<stage> copies out of another build stage, not out of the context.
        if ($rest -match '--from=') { continue }

        $sources = @()
        if ($rest.TrimStart().StartsWith('[')) {
            try {
                $values = @($rest | ConvertFrom-Json)
            }
            catch {
                continue
            }
            if ($values.Count -lt 2) { continue }
            # Exec form: every element but the last is a source.
            $sources = @($values[0..($values.Count - 2)])
        }
        else {
            # Shell form. Flags come first and are not sources. This split is wrong for
            # a path containing a space, which is why the result is only ever a warning.
            $parts = @($rest -split '\s+' | Where-Object { $_ -and -not $_.StartsWith('--') })
            if ($parts.Count -lt 2) { continue }
            $sources = @($parts[0..($parts.Count - 2)])
        }

        foreach ($source in $sources) {
            $value = "$source"
            if ($value -eq '') { continue }

            # Not a path in the context: a URL, an unresolved build arg, or a glob whose
            # matching this check would have to reimplement.
            if ($value -match '^\w+://' -or $value -match '\$' -or $value -match '[*?\[]') { continue }

            if (-not (Test-Path (Join-Path $BuildContext $value))) {
                $warnings += ("'$value' is copied by $Dockerfile but is not in the build context " +
                    "'$BuildContext'. Docker reports this as a cache-key error that never mentions the " +
                    "context; pass -BuildContext <the directory '$value' lives in>.")
            }
        }
    }

    # Returned as a plain array and NOT wrapped in ", $warnings": a function's output is
    # unrolled one level anyway, and the extra wrap makes the caller's `@(...)` produce a
    # single-element array OF the array - so every warning arrives as one joined string.
    return $warnings
}

function Invoke-PerfTestK6Job {
    <#
    Run one k6 scenario as a Kubernetes Job, wait for it, and collect its log.

    Extracted from the main flow when the preflight was added, because the preflight is
    a k6 Job too. Two copies of this sequence would drift, and the copy that lost the
    "wait for FAILED as well as Complete" fix is exactly the bug that used to block a
    red test for the full timeout before saying anything.

    Returns the outcome, k6's own exit code, and the pod, so the caller can record them.
    #>
    param(
        [Parameter(Mandatory = $true)][string] $JobName,
        [Parameter(Mandatory = $true)][string] $NamespaceName,
        [Parameter(Mandatory = $true)][string] $Type,
        [Parameter(Mandatory = $true)][string] $Script,
        [Parameter(Mandatory = $true)][string] $Url,
        [Parameter(Mandatory = $true)][string] $GeneratorImage,
        [Parameter(Mandatory = $true)][string] $PullPolicy,
        [Parameter(Mandatory = $true)][string] $CpuRequest,
        [Parameter(Mandatory = $true)][hashtable] $ScenarioEnv,
        [Parameter(Mandatory = $true)][string] $ManifestPath,
        [Parameter(Mandatory = $true)][string] $LogPath,
        [Parameter(Mandatory = $true)][int] $TimeoutSec,
        [Parameter(Mandatory = $true)][string] $Context,
        [string] $PrometheusWriteUrl = '',
        [string] $TestId = '',
        [string] $CredentialsSecret = '',
        [hashtable] $HostAliases = @{},
        [switch] $RemoveWhenDone
    )

    New-K6JobManifest `
        -Path $ManifestPath `
        -JobName $JobName `
        -NamespaceName $NamespaceName `
        -Type $Type `
        -Script $Script `
        -Url $Url `
        -GeneratorImage $GeneratorImage `
        -PullPolicy $PullPolicy `
        -CpuRequest $CpuRequest `
        -ScenarioEnv $ScenarioEnv `
        -PrometheusWriteUrl $PrometheusWriteUrl `
        -TestId $TestId `
        -CredentialsSecret $CredentialsSecret `
        -HostAliases $HostAliases | Out-Null

    Write-Host "  Job manifest: $ManifestPath"
    Write-Host "  Follow live:  kubectl logs -n $NamespaceName -l job-name=$JobName -f"

    Invoke-Kubectl -Arguments @('delete', 'job', $JobName, '-n', $NamespaceName, '--ignore-not-found=true') | Out-Null
    Invoke-Kubectl -Arguments @('apply', '-f', $ManifestPath) | Out-Null

    $waitStarted = Get-Date
    $outcome = Wait-K6Job -JobName $JobName -NamespaceName $NamespaceName -TimeoutSec $TimeoutSec -Context $Context
    $elapsed = [int]((Get-Date) - $waitStarted).TotalSeconds
    Write-Host "Job $JobName finished as $($outcome.Outcome) after ${elapsed}s." -ForegroundColor Cyan

    $pod = Get-JobPods -JobName $JobName -NamespaceName $NamespaceName | Select-Object -First 1
    $podName = ''
    $exitCode = 0
    $exitReason = ''

    if ($pod) {
        $podName = $pod.metadata.name
        $containerStatus = @($pod.status.containerStatuses) | Select-Object -First 1
        if ($containerStatus -and $containerStatus.state -and $containerStatus.state.terminated) {
            $exitCode = [int]$containerStatus.state.terminated.exitCode
            $exitReason = "$($containerStatus.state.terminated.reason)"
        }
    }

    if (-not $podName) {
        throw "No pod was found for Job $JobName, so there is no log to collect."
    }

    $logLines = Invoke-Kubectl -Arguments @('logs', $podName, '-n', $NamespaceName) -AllowFailure
    Write-Utf8NoBom -Path $LogPath -Content (($logLines -join "`n")) | Out-Null

    if ($RemoveWhenDone) {
        Invoke-Kubectl -Arguments @('delete', 'job', $JobName, '-n', $NamespaceName, '--ignore-not-found=true') | Out-Null
    }

    return [pscustomobject]@{
        Outcome    = "$($outcome.Outcome)"
        ExitCode   = $exitCode
        ExitReason = $exitReason
        PodName    = $podName
        Pod        = $pod
    }
}

function Get-PerfTestPodDiagnosis {
    <#
    One line per pod saying why it is not ready.

    kubectl reports a failed rollout as `timed out waiting for the condition`, which says
    nothing about the cause - and the cause is always visible in the pod's own status:
    ImagePullBackOff, a probe that never passed, or a container that exits immediately
    (a crash, a missing configuration value, a database it cannot reach). This collects
    that, so the failure is actionable where it happens instead of three commands later.

    Returns an empty array when nothing can be read, so it can never turn a rollout
    failure into a different, more confusing one.
    #>
    param(
        [Parameter(Mandatory = $true)][string] $NamespaceName,
        [Parameter(Mandatory = $true)][string] $LabelSelector
    )

    $lines = @()

    $text = (Invoke-Kubectl -Arguments @('get', 'pods', '-n', $NamespaceName, '-l', $LabelSelector, '-o', 'json') -AllowFailure) -join "`n"
    if (-not $text.Trim()) { return $lines }

    $pods = $null
    try {
        $pods = $text | ConvertFrom-Json
    }
    catch {
        return $lines
    }
    if (-not $pods.items) { return $lines }

    foreach ($pod in $pods.items) {
        $name = "$($pod.metadata.name)"
        $phase = "$($pod.status.phase)"
        $node = "$($pod.spec.nodeName)"
        $prefix = "pod $name [$phase on $node]"

        if ($pod.metadata.deletionTimestamp) {
            # A pod that is going away for a long time holds the rollout open: the
            # Deployment will not call it finished until the old pod is actually gone.
            $lines += "$prefix is terminating (deletionTimestamp set) - a slow or stuck shutdown holds the rollout open"
        }

        # Why the scheduled pods are not running.
        if ($phase -eq 'Pending' -and -not $pod.status.containerStatuses) {
            $reason = ''
            foreach ($condition in @($pod.status.conditions)) {
                if ("$($condition.type)" -eq 'PodScheduled' -and "$($condition.status)" -eq 'False') {
                    $reason = "$($condition.reason): $($condition.message)"
                }
            }
            $lines += if ($reason) { "$prefix cannot be scheduled - $reason" } else { "$prefix is Pending (no container status yet)" }
        }

        foreach ($status in @($pod.status.containerStatuses)) {
            $container = "$($status.name)"
            if ($status.state.waiting) {
                $lines += "$prefix container '$container' waiting: $($status.state.waiting.reason) - $($status.state.waiting.message)"
            }
            if ($status.lastState.terminated) {
                $terminated = $status.lastState.terminated
                $lines += "$prefix container '$container' last exited: $($terminated.reason) (exit code $($terminated.exitCode))"
            }
            if ([int]$status.restartCount -gt 0) {
                $lines += "$prefix container '$container' has restarted $($status.restartCount)x"
            }
        }

        # A failed probe is the other way a rollout stalls while the app looks alive.
        foreach ($condition in @($pod.status.conditions)) {
            if ("$($condition.type)" -eq 'ContainersReady' -and "$($condition.status)" -eq 'False' -and "$($condition.message)") {
                $lines += "$prefix not ready - $($condition.message)"
            }
        }
    }

    return $lines
}

function Get-JobPods {
    <# The Job's pods, newest first. Returns an empty array rather than throwing. #>
    param(
        [Parameter(Mandatory = $true)][string] $JobName,
        [Parameter(Mandatory = $true)][string] $NamespaceName
    )

    $text = (Invoke-Kubectl -Arguments @('get', 'pods', '-n', $NamespaceName, '-l', "job-name=$JobName", '-o', 'json') -AllowFailure) -join "`n"
    if (-not $text.Trim()) { return @() }

    try {
        $parsed = $text | ConvertFrom-Json
    }
    catch {
        return @()
    }

    if (-not $parsed.items) { return @() }

    return @($parsed.items | Sort-Object { $_.metadata.creationTimestamp } -Descending)
}

function Get-PerfTestApiRuntime {
    <#
    Read the API Deployment the way the CLUSTER runs it: image, replicas, the
    requests/limits the pods were actually scheduled with, and the QoS class that
    follows from them.

    Why this is read back rather than taken from the parameters: -TestOnly applies
    nothing, so a run can be measured against a deployment whose limits are not the
    ones on the command line. The README's first golden rule is that the measured
    configuration IS the experiment - and that rule is unenforceable unless the
    result states the configuration it was measured under. The caller compares this
    against what it asked for and warns when the two disagree.

    Returns an empty table when the Deployment cannot be read, so a metadata lookup
    can never cost a run its results.
    #>
    param([Parameter(Mandatory = $true)][string] $NamespaceName)

    $runtime = [ordered]@{}

    $deploymentText = (Invoke-Kubectl -Arguments @('get', 'deployment', 'api-deployment', '-n', $NamespaceName, '-o', 'json') -AllowFailure) -join "`n"
    if (-not $deploymentText.Trim()) { return $runtime }

    $deployment = $null
    try {
        $deployment = $deploymentText | ConvertFrom-Json
    }
    catch {
        return $runtime
    }
    if (-not $deployment -or -not $deployment.spec) { return $runtime }

    $containers = @($deployment.spec.template.spec.containers)
    $apiContainer = @($containers | Where-Object { $_.name -eq 'api' } | Select-Object -First 1)
    if ($apiContainer.Count -eq 0) { $apiContainer = @($containers | Select-Object -First 1) }
    $apiContainer = $apiContainer | Select-Object -First 1
    if (-not $apiContainer) { return $runtime }

    $requests = $apiContainer.resources.requests
    $limits = $apiContainer.resources.limits

    # Derived, not read: Kubernetes has no QoS field to query. Guaranteed means every
    # container has cpu AND memory requests EQUAL to its limits, which is exactly the
    # configuration in which a memory overrun OOMKills the pod rather than being
    # absorbed by slack on the node - worth knowing when the limit is the experiment.
    $guaranteed = $true
    foreach ($container in $containers) {
        $containerRequests = $container.resources.requests
        $containerLimits = $container.resources.limits
        if ($null -eq $containerRequests -or $null -eq $containerLimits) {
            $guaranteed = $false
            break
        }
        foreach ($resourceName in @('cpu', 'memory')) {
            if ("$($containerRequests.$resourceName)" -ne "$($containerLimits.$resourceName)") {
                $guaranteed = $false
                break
            }
        }
        if (-not $guaranteed) { break }
    }

    $runtime['source'] = 'cluster'
    $runtime['image'] = "$($apiContainer.image)"
    $runtime['replicas_desired'] = [int]$deployment.spec.replicas
    $runtime['replicas_ready'] = [int]$deployment.status.readyReplicas
    $runtime['cpu_request'] = "$($requests.cpu)"
    $runtime['cpu_limit'] = "$($limits.cpu)"
    $runtime['memory_request'] = "$($requests.memory)"
    $runtime['memory_limit'] = "$($limits.memory)"
    $runtime['qos_class'] = if ($guaranteed) { 'Guaranteed' } else { 'Burstable' }

    return $runtime
}

function Get-PerfTestPodNodes {
    <# Which nodes the pods matching a label selector are running on. Empty on failure. #>
    param(
        [Parameter(Mandatory = $true)][string] $NamespaceName,
        [Parameter(Mandatory = $true)][string] $LabelSelector
    )

    $text = (Invoke-Kubectl -Arguments @('get', 'pods', '-n', $NamespaceName, '-l', $LabelSelector, '-o', 'json') -AllowFailure) -join "`n"
    if (-not $text.Trim()) { return @() }

    try {
        $pods = $text | ConvertFrom-Json
    }
    catch {
        return @()
    }
    if (-not $pods.items) { return @() }

    return @($pods.items | ForEach-Object { "$($_.spec.nodeName)" } | Where-Object { $_ } | Sort-Object -Unique)
}

function Publish-PerfTestImage {
    <#
    Load ONE locally-built image into kind/minikube, where the docker daemon is not shared.

    -Required changes a silent skip into a warning that names the fix. The generator image
    is always required: unlike the API image, it is never pulled from a registry, so if it
    is not in the cluster the Job cannot start and the pod sits in ImagePullBackOff while
    the summary the caller is waiting for never appears. That is precisely how a
    -TestOnly run against a local cluster fails today, because the build-and-publish step
    used to live entirely inside the deploy branch.
    #>
    param(
        [Parameter(Mandatory = $true)][string] $Context,
        [Parameter(Mandatory = $true)][string] $Candidate,
        [switch] $Required
    )

    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        if ($Required) {
            Write-Warning ("docker is not on PATH, so '$Candidate' was not loaded into the cluster. The Job will fail " +
                "with ImagePullBackOff unless the cluster can already see it: $(Get-LocalImagePublishHint -Context $Context)")
        }
        return
    }

    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $inspectOutput = (& docker image inspect $Candidate 2>&1 | Out-String)
        $exists = ($LASTEXITCODE -eq 0)
    }
    finally {
        $ErrorActionPreference = $previous
    }

    if (-not $exists) {
        if ($Required) {
            # Say which of the two situations this is. "Permission denied while trying to
            # connect to the docker API" means the daemon is unreachable (on Windows,
            # usually Docker Desktop not running), not that the image is missing - and the
            # fix is completely different.
            $daemonUnreachable = ($inspectOutput -match '(?i)(permission denied|error during connect|cannot connect|pipe|is the docker daemon running)')
            if ($daemonUnreachable) {
                Write-Warning ("The Docker daemon could not be reached, so '$Candidate' was not loaded into the cluster and " +
                    "the k6 Job will fail with ImagePullBackOff. Start Docker Desktop (or the daemon) and re-run, or build and " +
                    "load it by hand:`n  docker build -f k6/Dockerfile -t $Candidate .`n  minikube image load $Candidate")
            }
            else {
                Write-Warning ("'$Candidate' is not in the local Docker daemon, so it was not loaded into the cluster and the " +
                    "k6 Job will fail with ImagePullBackOff. Build it first, or run without -TestOnly so this runner builds it:`n" +
                    "  docker build -f k6/Dockerfile -t $Candidate .")
            }
        }
        return
    }

    if ($Context -like 'kind-*') {
        if (-not (Get-Command kind -ErrorAction SilentlyContinue)) {
            Write-Warning "kind context detected but the 'kind' CLI is not on PATH. Load it manually: kind load docker-image $Candidate"
            return
        }
        Write-Host "Loading $Candidate into kind..." -ForegroundColor Cyan
        Invoke-Checked 'kind' @('load', 'docker-image', $Candidate)
    }
    elseif ($Context -like 'minikube*') {
        if (-not (Get-Command minikube -ErrorAction SilentlyContinue)) {
            Write-Warning "minikube context detected but the 'minikube' CLI is not on PATH. Load it manually: minikube image load $Candidate"
            return
        }

        # NOTE: `minikube image load` has no --nodes flag (checked against
        # v1.37), so the image cannot be targeted at a specific node from here.
        #
        # The trap this leaves: the node's container runtime keys images by TAG,
        # and with imagePullPolicy IfNotPresent a Job can be scheduled onto a
        # node still holding the previous build of the same tag. k6 then fails
        # with "the module /scripts/<file>.js couldn't be found on local disk"
        # for a file that is plainly in k6/scripts and plainly inside the image
        # on the host. Rebuilding does not fix it; the stale copy on the node
        # has to go. Either:
        #
        #   docker exec <node> docker rmi -f <image>   # for each node, then re-run
        #
        # or, if that is fiddly, `minikube delete && minikube start` for a clean
        # cluster. Bump the tag instead (-K6Image k6-custom:2) - a different tag
        # is always a cache miss on every node, which is the cheapest fix of all.
        Write-Host "Loading $Candidate into minikube..." -ForegroundColor Cyan
        Invoke-Checked 'minikube' @('image', 'load', $Candidate)
    }
}

function Get-LocalImagePublishHint {
    <# Local clusters cannot see the host docker daemon unless the image is loaded. #>
    param([Parameter(Mandatory = $true)][string] $Context)

    if ($Context -like 'kind-*') {
        return "kind load docker-image $Image; kind load docker-image $K6Image"
    }
    if ($Context -like 'minikube*') {
        return "minikube image load $Image; minikube image load $K6Image"
    }
    return "make sure the cluster can pull '$Image' and '$K6Image' (push them to a registry the cluster can reach)"
}

function Publish-LocalImages {
    <# Load every locally-built image the run needs into kind/minikube. #>
    param([Parameter(Mandatory = $true)][string] $Context)

    Publish-PerfTestImage -Context $Context -Candidate $Image
    Publish-PerfTestImage -Context $Context -Candidate $K6Image -Required
}

function Wait-K6Job {
    <#
    Wait for the Job to reach Complete or Failed, and fail fast on the states that
    will never resolve.

    `kubectl wait --for=condition=complete` - what this used to do - never returns
    early when k6 exits 99, so a red threshold test blocked for the entire timeout
    before saying anything at all.
    #>
    param(
        [Parameter(Mandatory = $true)][string] $JobName,
        [Parameter(Mandatory = $true)][string] $NamespaceName,
        [Parameter(Mandatory = $true)][int] $TimeoutSec,
        [Parameter(Mandatory = $true)][string] $Context
    )

    $fatalWaitingReasons = @(
        'ImagePullBackOff', 'ErrImagePull', 'InvalidImageName',
        'CreateContainerConfigError', 'CreateContainerError', 'RunContainerError'
    )

    $startedAt = Get-Date
    $deadline = $startedAt.AddSeconds($TimeoutSec)
    $lastHeartbeat = $startedAt

    while ($true) {
        $jobText = (Invoke-Kubectl -Arguments @('get', 'job', $JobName, '-n', $NamespaceName, '-o', 'json')) -join "`n"
        $job = $jobText | ConvertFrom-Json

        $terminal = @($job.status.conditions | Where-Object {
                $_.status -eq 'True' -and ($_.type -eq 'Complete' -or $_.type -eq 'Failed')
            })
        if ($terminal.Count -gt 0) {
            return [pscustomobject]@{
                Outcome = $terminal[0].type
                Reason  = "$($terminal[0].reason)"
                Message = "$($terminal[0].message)"
            }
        }

        $pods = Get-JobPods -JobName $JobName -NamespaceName $NamespaceName
        $pod = $pods | Select-Object -First 1
        $podName = if ($pod) { $pod.metadata.name } else { '' }

        if ($pod) {
            $containerStatus = @($pod.status.containerStatuses) | Select-Object -First 1
            $waitingReason = ''
            if ($containerStatus -and $containerStatus.state -and $containerStatus.state.waiting) {
                $waitingReason = "$($containerStatus.state.waiting.reason)"
            }

            if ($waitingReason -and ($fatalWaitingReasons -contains $waitingReason)) {
                $detail = "$($containerStatus.state.waiting.message)"
                throw ("The k6 pod could not start ($waitingReason): $detail`n" +
                    "Hint: $(Get-LocalImagePublishHint -Context $Context)")
            }

            $unschedulable = @($pod.status.conditions | Where-Object {
                    $_.type -eq 'PodScheduled' -and $_.status -eq 'False'
                })
            if ($unschedulable.Count -gt 0 -and $pod.status.phase -eq 'Pending') {
                $podAge = (Get-Date) - ([datetime]$pod.metadata.creationTimestamp).ToLocalTime()
                if ($podAge.TotalSeconds -gt 60) {
                    throw ("The k6 pod has been Pending for $([int]$podAge.TotalSeconds)s and cannot be scheduled: $($unschedulable[0].message)`n" +
                        'Hint: lower -K6CpuRequest, or free capacity on the node.')
                }
            }
        }

        if ((Get-Date) -ge $deadline) {
            $status = if ($pod) { "pod $podName is in phase $($pod.status.phase)" } else { 'no pod exists yet' }
            throw "Timed out after ${TimeoutSec}s waiting for Job $JobName ($status)."
        }

        if (((Get-Date) - $lastHeartbeat).TotalSeconds -ge 30) {
            $phase = if ($pod) { "$($pod.status.phase)" } else { 'no pod yet' }
            $elapsed = [int]((Get-Date) - $startedAt).TotalSeconds
            Write-Host "  ... still running (${phase}, ${elapsed}s elapsed)" -ForegroundColor DarkGray
            $lastHeartbeat = Get-Date
        }

        Start-Sleep -Seconds 5
    }
}

# ---------------------------------------------------------------------------
# Re-parse mode: no cluster, no docker, no deployment.
# ---------------------------------------------------------------------------
if ($FromLog) {
    $logPath = (Resolve-Path $FromLog).Path
    $runDirectory = Split-Path -Parent $logPath
    $revision = Get-PerfTestGitRevision

    $summary = Write-PerfTestResult `
        -LogPath $logPath `
        -SummaryPath (Join-Path $runDirectory 'summary.json') `
        -MetaPath (Join-Path $runDirectory 'meta.json') `
        -RunDirectory $runDirectory `
        -Metadata @{
            schema       = 'perftest.run/v1'
            runner       = 'scripts/deploy-and-test.ps1'
            source       = 'from-log'
            test_type    = $TestType
            # Recovered from the run directory, which is named after the run's testid -
            # so a re-parsed log still lines up with the Grafana series it produced.
            testid       = Split-Path -Leaf $runDirectory
            target_url   = $TargetUrl
            scenario     = $scenarioFile
            git_revision = $revision
            started_at   = (Get-Date).ToUniversalTime().ToString('o')
        }

    if (-not $summary.thresholds_all_ok) { exit 99 }
    exit 0
}

if ($TestOnly -and $DeployOnly) {
    throw '-TestOnly and -DeployOnly are mutually exclusive.'
}

# ---------------------------------------------------------------------------
# Validate the target before doing anything expensive.
# ---------------------------------------------------------------------------
if ($TargetUrl -and $TargetUrl -notmatch '^https?://') {
    throw "TargetUrl must start with http:// or https://, but got '$TargetUrl'. Inside the cluster it usually looks like http://api-service:8080/api/health."
}

if ($TargetUrl -and $TargetUrl -match 'swagger') {
    Write-Warning "'$TargetUrl' looks like Swagger UI. That is a static HTML page, served by middleware that is normally disabled outside Development: it exercises neither your API logic nor your database. Point -TargetUrl at a real endpoint."
}

$testEnv = ConvertTo-PerfTestEnvTable -EnvVars $EnvVars
$appEnv = ConvertTo-PerfTestEnvTable -EnvVars $AppEnvVars

if ($testEnv.ContainsKey('TARGET_URL')) {
    throw 'TARGET_URL cannot be set through -EnvVars: use -TargetUrl, which is validated and recorded.'
}

# The journey scenario logs in itself (once, or once per account when a pool is configured),
# so the generic token machinery in lib/auth.js is redundant for it - and leaving it on costs
# a second login per VU on the first iteration, at the moment the identity provider is under
# the most pressure. The two wrapper runners already pass AUTH_MODE=off; this is that same
# default for a direct call to this runner.
#
# Only when nothing was set: an explicit AUTH_MODE is the caller's decision, and the scenario
# warns about the duplicate logins when it sees one.
if ($scenarioFile -eq 'journey-test.js' -and -not $testEnv.ContainsKey('AUTH_MODE')) {
    $testEnv['AUTH_MODE'] = 'off'
    Write-Host 'Journey test: AUTH_MODE=off (the scenario authenticates itself).' -ForegroundColor DarkGray
}

# ---------------------------------------------------------------------------
# Addresses the generator must be able to reach, resolved here rather than in the cluster.
#
# Resolved before the Job manifest is written (and before -EmitJobManifest exits), so the
# manifest that gets archived - and the one a reviewer reads in a pull request - is the
# one that runs.
# ---------------------------------------------------------------------------
$hostAliases = [ordered]@{}
foreach ($resolveName in $ResolveHost) {
    if (-not $resolveName) { continue }

    $address = Get-PerfTestHostAddress -HostName $resolveName
    if (-not $address) {
        Write-Warning ("Could not resolve '$resolveName' on this machine, so it was not pinned in the k6 Job. " +
            "If the cluster's DNS cannot resolve it either, the run will fail with a DNS error before its first request.")
        continue
    }

    $hostAliases[$resolveName] = $address
}

if ($hostAliases.Count -gt 0) {
    Write-Host 'Pinned in the k6 Job (resolved on this machine):' -ForegroundColor DarkGray
    foreach ($aliasHost in ($hostAliases.Keys | Sort-Object)) {
        Write-Host "  $aliasHost -> $($hostAliases[$aliasHost])" -ForegroundColor DarkGray
    }
}

if ($EmitJobManifest) {
    $manifestPath = $EmitJobManifest
    if (-not [System.IO.Path]::IsPathRooted($manifestPath)) {
        $manifestPath = Join-Path (Get-Location).Path $manifestPath
    }

    New-K6JobManifest `
        -Path $manifestPath `
        -JobName "k6-test-$TestType" `
        -NamespaceName $Namespace `
        -Type $TestType `
        -Script $scenarioFile `
        -Url $TargetUrl `
        -GeneratorImage $K6Image `
        -PullPolicy $ImagePullPolicy `
        -CpuRequest $K6CpuRequest `
        -ScenarioEnv $testEnv `
        -PrometheusWriteUrl $PrometheusWriteUrl `
        -CredentialsSecret $CredentialsSecret `
        -HostAliases $hostAliases `
        -TestId (New-PerfTestId -TestType $TestType) | Out-Null

    Write-Host "Wrote the Job manifest to $manifestPath" -ForegroundColor Cyan
    Write-Host 'Nothing was deployed and no test was run (-EmitJobManifest).' -ForegroundColor DarkGray
    exit 0
}

# A run directory only makes sense once there is a run to record.
$runDirectory = $null
$logPath = $null
$summaryPath = $null
$metaPath = $null
$jobName = $null
$metadata = $null

if (-not $DeployOnly) {
    $runDirectory = New-PerfTestRunDirectory -ResultsRoot $resultsRoot -Name $TestType
    $logPath = Join-Path $runDirectory 'k6.log'
    $summaryPath = Join-Path $runDirectory 'summary.json'
    $metaPath = Join-Path $runDirectory 'meta.json'
    $jobName = "k6-test-$TestType"

    # The run's own id, taken from the directory the run writes into rather than
    # generated again: the k6 Job is tagged with it and the Grafana link filters on it,
    # so it has to be the same string as the artefact directory name.
    $testId = Split-Path -Leaf $runDirectory

    $revision = Get-PerfTestGitRevision
    $metadata = @{
        schema              = 'perftest.run/v1'
        runner              = 'scripts/deploy-and-test.ps1'
        test_type           = $TestType
        testid              = $testId
        target_url          = $TargetUrl
        scenario            = $scenarioFile
        namespace           = $Namespace
        api_image           = $Image
        k6_image            = $K6Image
        image_pull_policy   = $ImagePullPolicy
        replicas            = $Replicas
        runtime_environment = $RuntimeEnvironment
        # The generator's own resources, so a result can be read against the generator
        # that produced it. Its memory request and limit are constants in the Job
        # manifest, which is archived next to these results.
        k6_cpu_request      = $K6CpuRequest
        # Masked on purpose, for the same reason as the compose runner: an artefact
        # containing a credential gets shared far more widely than it should.
        #
        # NOTE the archived Job manifest (results/<run>/k6-job.yaml) still contains
        # -EnvVars values verbatim, because it is the exact file that was applied and the
        # Job needs the real values to run. That is precisely why credentials for a
        # cluster run belong in a Kubernetes Secret referenced with envFrom/secretKeyRef,
        # not in -EnvVars.
        env_vars            = (Protect-PerfTestSecretValues -Environment $testEnv)
        job_name            = $jobName
        git_revision        = $revision
        started_at          = (Get-Date).ToUniversalTime().ToString('o')
    }

    # What this run ASKED the API to run with. Recorded only when the run actually
    # applied the overlay: under -TestOnly the Deployment is reused untouched, so these
    # parameter values describe nothing, and api_resources_observed (filled in after the
    # run) is the only trustworthy record of what the numbers were measured under.
    if (-not $TestOnly) {
        $metadata['api_resources_requested'] = [ordered]@{
            cpu_request    = $CpuRequest
            cpu_limit      = $CpuLimit
            memory_request = $MemoryRequest
            memory_limit   = $MemoryLimit
        }
    }

    # Addresses pinned into the generator's /etc/hosts. Recorded because a result that
    # reached a pinned address is a result about that address: if the name starts
    # resolving somewhere else, the numbers may not be comparable.
    if ($hostAliases.Count -gt 0) {
        $metadata['host_aliases'] = $hostAliases
    }
}

# ---------------------------------------------------------------------------
# Deploy the system under test.
# ---------------------------------------------------------------------------
$kubectlContext = ((Invoke-Kubectl -Arguments @('config', 'current-context') -AllowFailure) -join '').Trim()
if (-not $kubectlContext) {
    throw 'kubectl has no current context. Point it at a cluster first (kubectl config use-context <name>).'
}
Write-Host "Cluster context: $kubectlContext" -ForegroundColor Cyan
if ($metadata) {
    $metadata['kubectl_context'] = $kubectlContext
}

$builtImages = $false

if (-not $TestOnly) {
    if ($BuildEnv -eq 'Development') {
        Write-Warning 'Building the API with -BuildEnv Development produces a Debug-oriented image. Numbers from it are not usable for capacity planning or release decisions.'
    }

    # ---------------------------------------------------------------------
    # Build the API image.
    #
    # Two ways in, and they are not equivalent:
    #
    #   -Dockerfile + -BuildContext
    #       any Dockerfile, built from a context you name. This is the honest form: a
    #       Dockerfile is meaningless without its context, and a context guessed from
    #       the Dockerfile's location is how a build silently uses the wrong sources.
    #
    #   -ApiPath
    #       shorthand for "<path>/Dockerfile" with the context guessed three levels up.
    #       It encodes another repository's layout and is on the way out.
    # ---------------------------------------------------------------------
    $dockerfileForBuild = $null
    $buildContext = $null
    $buildArguments = @()
    $tempDockerfile = $null

    try {
        if ($Dockerfile) {
            if (-not (Test-Path $Dockerfile -PathType Leaf)) {
                throw "-Dockerfile was not found: $Dockerfile"
            }
            $dockerfileForBuild = (Resolve-Path $Dockerfile).Path

            if ($BuildContext) {
                if (-not (Test-Path $BuildContext -PathType Container)) {
                    throw "-BuildContext is not a directory: $BuildContext"
                }
                $buildContext = (Resolve-Path $BuildContext).Path
            }
            else {
                # A COPY can never reach above its context, so the Dockerfile's own
                # directory is the only default that can work for a self-contained
                # Dockerfile. One that copies from the repository root needs an explicit
                # -BuildContext, and the check below names what would be missing.
                $buildContext = Split-Path -Parent $dockerfileForBuild
            }

            $buildArguments = @($BuildArg)
            Write-Host "Building API image $Image from $dockerfileForBuild (context: $buildContext)..." -ForegroundColor Cyan

            foreach ($contextWarning in (Test-PerfTestDockerContext -Dockerfile $dockerfileForBuild -BuildContext $buildContext)) {
                Write-Warning $contextWarning
            }
        }
        elseif ($ApiPath) {
            # Legacy shorthand. Prefer -Image with an image your CI published, or
            # -Dockerfile with -BuildContext.
            $apiPath = (Resolve-Path $ApiPath).Path
            $apiDockerfile = Join-Path $apiPath 'Dockerfile'
            if (-not (Test-Path $apiDockerfile -PathType Leaf)) {
                throw "Dockerfile was not found at $apiDockerfile."
            }

            $buildContext = (Get-Item (Join-Path $apiPath '..\..\..')).FullName
            $rootNugetConfig = Join-Path $buildContext 'nuget.config'
            $newCoreNugetConfig = Join-Path $buildContext 'NewCore\nuget.config'

            if (-not (Test-Path $rootNugetConfig -PathType Leaf) -and (Test-Path $newCoreNugetConfig -PathType Leaf)) {
                # The checked-in Dockerfile references nuget.config at the context
                # root, while that repository stores it under NewCore. Build from a
                # patched copy so the source tree is left untouched.
                $tempDockerfile = Join-Path ([System.IO.Path]::GetTempPath()) 'perf-test-kit-api.Dockerfile'
                Write-Utf8NoBom -Path $tempDockerfile -Content ((Get-Content $apiDockerfile -Raw).Replace('COPY ["nuget.config", "."]', 'COPY ["NewCore/nuget.config", "."]')) | Out-Null
                $dockerfileForBuild = $tempDockerfile
            }
            else {
                $dockerfileForBuild = $apiDockerfile
            }

            # ENVIRONMENT is that repository's build arg, so it is passed only on this
            # path: a Dockerfile the caller named may not declare it, and an undeclared
            # --build-arg is a warning nobody reads.
            $buildArguments = @("ENVIRONMENT=$BuildEnv")
            Write-Host "Building API image $Image from $apiPath..." -ForegroundColor Cyan
        }

        if ($dockerfileForBuild) {
            $dockerBuildArguments = @('build', '-f', $dockerfileForBuild, '-t', $Image)
            foreach ($pair in $buildArguments) {
                $dockerBuildArguments += @('--build-arg', $pair)
            }
            $dockerBuildArguments += $buildContext
            Invoke-Checked 'docker' $dockerBuildArguments
            $builtImages = $true
        }
    }
    finally {
        if ($tempDockerfile -and (Test-Path $tempDockerfile)) {
            Remove-Item $tempDockerfile -Force
        }
    }

    Write-Host "Building k6 image $K6Image..." -ForegroundColor Cyan
    Invoke-Checked 'docker' @('build', '-f', (Join-Path $repoRoot 'k6\Dockerfile'), '-t', $K6Image, $repoRoot)
    $builtImages = $true
    if ($metadata) {
        $metadata['api_image_built_locally'] = $builtImages
    }

    Publish-LocalImages -Context $kubectlContext

    $kustomizeDirectory = Join-Path $repoRoot 'k8s\.generated'
    if (-not (Test-Path $kustomizeDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $kustomizeDirectory -Force | Out-Null
    }
    $overlayDirectory = Join-Path $kustomizeDirectory $Namespace
    if (Test-Path $overlayDirectory -PathType Container) {
        Remove-Item $overlayDirectory -Recurse -Force
    }
    New-Item -ItemType Directory -Path $overlayDirectory -Force | Out-Null
    New-PerfTestOverlay `
        -OverlayDirectory $overlayDirectory `
        -NamespaceName $Namespace `
        -ImageReference $Image `
        -PullPolicy $ImagePullPolicy `
        -ReplicaCount $Replicas `
        -Environment $RuntimeEnvironment `
        -CpuRequest $CpuRequest `
        -CpuLimit $CpuLimit `
        -MemoryRequest $MemoryRequest `
        -MemoryLimit $MemoryLimit `
        -AppEnvironment $appEnv | Out-Null

    # Archive the exact patch that was applied. The overlay is regenerated on the next
    # run, so without this copy a past run's measured configuration is gone - which is
    # how "two runs with different limits are two different experiments" becomes
    # unenforceable in practice.
    if ($runDirectory) {
        Copy-Item -Path (Join-Path $overlayDirectory 'runtime-settings.yaml') -Destination (Join-Path $runDirectory 'runtime-settings.yaml') -Force
        $metadata['runtime_settings_file'] = 'runtime-settings.yaml'
    }

    Write-Host 'Deploying the API under test...' -ForegroundColor Cyan

    # Say what this deploy is about to CHANGE, before it changes it.
    #
    # The running Deployment IS the experiment's configuration, and the runner's defaults
    # are small (250m CPU / 512Mi). A run that mentions no resources therefore re-sizes a
    # carefully sized pod without anyone noticing, and the next comparison is between two
    # different experiments - the one thing the golden rules forbid. Reported, not blocked:
    # changing the size on purpose is exactly what -MemoryLimit 4Gi is for.
    $beforeRuntime = Get-PerfTestApiRuntime -NamespaceName $Namespace
    if ($beforeRuntime.Count -gt 0) {
        $pendingChanges = @()
        foreach ($field in @('cpu_request', 'cpu_limit', 'memory_request', 'memory_limit')) {
            $was = "$($beforeRuntime[$field])"
            $now = switch ($field) {
                'cpu_request' { $CpuRequest }
                'cpu_limit' { $CpuLimit }
                'memory_request' { $MemoryRequest }
                'memory_limit' { $MemoryLimit }
            }
            if ($was -ne "$now") { $pendingChanges += "$field : $was -> $now" }
        }
        if ("$($beforeRuntime['image'])" -and "$($beforeRuntime['image'])" -ne $Image) {
            $pendingChanges += "image : $($beforeRuntime['image']) -> $Image"
        }
        if ([int]$beforeRuntime['replicas_desired'] -ne $Replicas) {
            $pendingChanges += "replicas : $($beforeRuntime['replicas_desired']) -> $Replicas"
        }

        if ($pendingChanges.Count -gt 0) {
            Write-Host 'This deploy changes the running configuration:' -ForegroundColor Yellow
            foreach ($change in $pendingChanges) { Write-Host "  $change" -ForegroundColor Yellow }
            Write-Host '  A result is only comparable with another measured under the same configuration.' -ForegroundColor DarkGray
        }
    }

    Invoke-Kubectl -Arguments @('apply', '-k', $overlayDirectory) | Out-Null

    # Read the image back BEFORE waiting for a rollout, because a Deployment whose image
    # is not the requested one cannot roll out at all: the new pod sits in
    # ImagePullBackOff until the 300s timeout, and kubectl's message ("timed out waiting
    # for the condition") never mentions the image. That is exactly how a placeholder
    # image shipped from this runner for days: the overlay's images: transformer named a
    # container that did not exist, so it silently substituted nothing.
    $appliedRuntime = Get-PerfTestApiRuntime -NamespaceName $Namespace
    if ($appliedRuntime.Count -gt 0 -and $appliedRuntime['image']) {
        if ("$($appliedRuntime['image'])" -ne $Image) {
            throw ("The Deployment was applied with image '$($appliedRuntime['image'])', not '$Image'. " +
                "The rollout would fail with ImagePullBackOff and a timeout that does not mention the image. " +
                "Check the overlay: kubectl kustomize '$overlayDirectory' | Select-String 'image:'")
        }
        Write-Host "  image       : $($appliedRuntime['image'])" -ForegroundColor DarkGray
    }

    # A reused tag plus a non-Always pull policy means the node can keep serving
    # the previous build, with no rollout triggered because the spec never changed.
    # Restart so the run is guaranteed to exercise what was just built.
    Invoke-Kubectl -Arguments @('rollout', 'restart', 'deployment/api-deployment', '-n', $Namespace) | Out-Null

    Write-Host 'Waiting for the API to become ready...' -ForegroundColor Cyan
    try {
        Invoke-Kubectl -Arguments @('rollout', 'status', 'deployment/api-deployment', '-n', $Namespace, '--timeout=300s') | Out-Null
    }
    catch {
        # kubectl's own failure is a timeout with no cause attached. Print the cause - why
        # each pod of the Deployment is not ready - before letting the error through, so
        # the operator does not have to reconstruct it from three kubectl commands.
        Write-Host ''
        Write-Warning 'The API did not become ready. Why each of its pods is not ready:'
        foreach ($line in (Get-PerfTestPodDiagnosis -NamespaceName $Namespace -LabelSelector 'app=api')) {
            Write-Host "  $line" -ForegroundColor DarkGray
        }
        Write-Host "  Full detail: kubectl describe pods -n $Namespace -l app=api" -ForegroundColor DarkGray
        throw
    }

    if ($DeployOnly) {
        Write-Host 'Deployment is ready (-DeployOnly).' -ForegroundColor Green
        exit 0
    }
}
elseif ($DeployOnly) {
    throw '-DeployOnly cannot be combined with -TestOnly.'
}
else {
    # -TestOnly reuses the Deployment, so the API image is already in the cluster - but the
    # GENERATOR image is not: it is built here and never pulled from a registry. This step
    # used to live entirely inside the deploy branch, so a -TestOnly run against
    # kind/minikube left the k6 Job in ImagePullBackOff while the caller waited for a
    # summary that could never arrive.
    Publish-PerfTestImage -Context $kubectlContext -Candidate $K6Image -Required
}

# ---------------------------------------------------------------------------
# Credentials.
#
# Checked here rather than left to the pod: a missing Secret makes the container fail
# with CreateContainerConfigError, which reads like a cluster problem, while the actual
# message ("secret not found") is several kubectl commands away. Also recorded by NAME
# only - the whole point of the Secret is that its contents stay out of the artefacts.
# ---------------------------------------------------------------------------
if ($CredentialsSecret) {
    $secretText = (Invoke-Kubectl -Arguments @('get', 'secret', $CredentialsSecret, '-n', $Namespace, '-o', 'json') -AllowFailure) -join "`n"
    if ($secretText -notmatch '"kind"\s*:\s*"Secret"') {
        throw ("Secret '$CredentialsSecret' was not found in namespace '$Namespace'. The k6 Job injects its keys as " +
            "environment variables, so without it the pod never starts.`n" +
            "Create it from your .env, for example:`n" +
            "  kubectl create secret generic $CredentialsSecret -n $Namespace " +
            "--from-literal=LOGIN_URL=... --from-literal=JOURNEY_USERNAME=... --from-literal=JOURNEY_PASSWORD=...`n" +
            'or use scripts/run-cluster-test.ps1, which does this from k6\.env for you.')
    }
    $metadata['credentials_secret'] = $CredentialsSecret
}

# ---------------------------------------------------------------------------
# Preflight: make the target prove it answers FROM INSIDE THE CLUSTER before spending
# the profile's duration on it.
#
# This is the same idea as the compose runner's preflight, and it has to run in-cluster
# to be worth anything: the k6 Job reaches the API by Service name, so only a pod can
# tell you whether that resolves and routes. A twelve-minute load test that is 100%
# connection failures - or 100% 401s because the credentials never reached the pod - is
# the most expensive possible way to learn either.
#
# The journey type preflights with the JOURNEY, not with smoke: a protected endpoint
# answers 401 to an unauthenticated request, so a smoke preflight would report the
# target as dead when what is dead is the anonymous request.
# ---------------------------------------------------------------------------
$preflightStatus = 'skipped'
$preflightFailureRate = $null

if ($Preflight -and $TestType -ne 'smoke') {
    $preflightScript = if ($TestType -eq 'journey') { 'journey-test.js' } else { 'smoke-test.js' }
    $preflightEnv = @{}
    foreach ($name in $testEnv.Keys) { $preflightEnv[$name] = $testEnv[$name] }
    $preflightEnv['TARGET_VUS'] = '1'
    $preflightEnv['REQUEST_PAUSE'] = '0'
    $preflightEnv['STEP_PAUSE'] = '0'
    $preflightEnv['TEST_DURATION'] = if ($TestType -eq 'journey') { '6s' } else { '4s' }

    $preflightLogPath = Join-Path $runDirectory 'preflight.log'
    $preflightJobName = "k6-preflight-$TestType"

    Write-Host ''
    Write-Host "Preflight: 1 VU of $preflightScript against $TargetUrl, from inside the cluster..." -ForegroundColor Cyan

    $preflightResult = Invoke-PerfTestK6Job `
        -JobName $preflightJobName `
        -NamespaceName $Namespace `
        -Type 'preflight' `
        -Script $preflightScript `
        -Url $TargetUrl `
        -GeneratorImage $K6Image `
        -PullPolicy $ImagePullPolicy `
        -CpuRequest $K6CpuRequest `
        -ScenarioEnv $preflightEnv `
        -ManifestPath (Join-Path $runDirectory 'preflight-job.yaml') `
        -LogPath $preflightLogPath `
        -TimeoutSec 300 `
        -Context $kubectlContext `
        -PrometheusWriteUrl $PrometheusWriteUrl `
        -TestId "$testId-preflight" `
        -CredentialsSecret $CredentialsSecret `
        -HostAliases $hostAliases `
        -RemoveWhenDone

    $preflightText = if (Test-Path $preflightLogPath -PathType Leaf) { Get-Content -Path $preflightLogPath -Raw } else { '' }
    $preflightSummary = $null
    try {
        $preflightSummary = Get-K6SummaryFromText -Text $preflightText
    }
    catch {
        $preflightSummary = $null
    }

    $preflightFailureRate = $null
    if ($preflightSummary -and $preflightSummary.metrics -and $preflightSummary.metrics.http_req_failed) {
        $preflightFailureRate = [double]$preflightSummary.metrics.http_req_failed.rate
    }

    # The gate is the failure RATE, not k6's exit code: a preflight against a slow but
    # healthy endpoint can exit 99 on a latency threshold while every request succeeded,
    # and refusing to run the real test over that would be wrong.
    if ($null -eq $preflightFailureRate -or $preflightFailureRate -ge 1) {
        $causes = @(($preflightText -split "`r?`n") | Where-Object {
                $_ -match 'level=error|Request Failed|Error response|no such host|connection refused|error='
            } | Select-Object -First 3)

        Write-Host ''
        Write-Warning "Not one request succeeded, so the $TestType test would measure nothing but failures."
        $causes | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
        Write-Host "  Preflight log: $preflightLogPath"
        Write-Host 'Check, in order:'
        Write-Host "  1. the Service must route somewhere: kubectl get endpoints api-service -n $Namespace"
        Write-Host '  2. the path must exist on that route - a 404 counts as a failed request here'
        Write-Host '  3. if the endpoint is protected, a 401/403 counts as a failed request too: check the'
        Write-Host '     credentials reached the pod (-CredentialsSecret, or -EnvVars)'
        Write-Host '  4. the API itself must be ready: kubectl get pods -n ' + $Namespace
        Write-Host 'Re-run with -Preflight:$false (or omit -Preflight) to run anyway.'
        exit 2
    }

    $preflightStatus = 'passed'
    Write-Host ('Preflight OK: {0:P0} of requests failed.' -f $preflightFailureRate) -ForegroundColor Green
}

if ($metadata) {
    $metadata['preflight'] = $preflightStatus
}
if ($preflightFailureRate -ne $null) {
    $metadata['preflight_failure_rate'] = $preflightFailureRate
}

# ---------------------------------------------------------------------------
# Run the test.
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host "Running the $TestType test against $TargetUrl ..." -ForegroundColor Cyan

$jobResult = Invoke-PerfTestK6Job `
    -JobName $jobName `
    -NamespaceName $Namespace `
    -Type $TestType `
    -Script $scenarioFile `
    -Url $TargetUrl `
    -GeneratorImage $K6Image `
    -PullPolicy $ImagePullPolicy `
    -CpuRequest $K6CpuRequest `
    -ScenarioEnv $testEnv `
    -ManifestPath (Join-Path $runDirectory 'k6-job.yaml') `
    -LogPath $logPath `
    -TimeoutSec $TimeoutSeconds `
    -Context $kubectlContext `
    -PrometheusWriteUrl $PrometheusWriteUrl `
    -TestId $testId `
    -CredentialsSecret $CredentialsSecret `
    -HostAliases $hostAliases

$pod = $jobResult.Pod
$podName = $jobResult.PodName
$exitCode = $jobResult.ExitCode
$exitReason = $jobResult.ExitReason
$metadata['pod_name'] = $podName

# ---------------------------------------------------------------------------
# Record the configuration these numbers were actually measured under.
#
# Requested values are not enough. Under -TestOnly nothing is applied, and even after
# a deploy the thing answering requests is what the cluster scheduled - so the live
# spec is read back and compared with the request. That comparison is what catches
# "I passed -MemoryLimit 4Gi and measured a 2Gi deployment", which otherwise produces
# a perfectly valid summary filed under the wrong experiment.
# ---------------------------------------------------------------------------
$observed = Get-PerfTestApiRuntime -NamespaceName $Namespace

if ($observed.Count -eq 0) {
    $metadata['api_resources_observed'] = [ordered]@{ source = 'unavailable' }
    Write-Warning ("The API Deployment could not be read back from cluster '$kubectlContext', so meta.json does " +
        'not record the CPU/memory this run was measured under. The summary is still valid; its configuration is not.')
}
else {
    if ($pod -and $pod.spec.nodeName) {
        $observed['k6_node'] = "$($pod.spec.nodeName)"
    }

    $apiNodes = Get-PerfTestPodNodes -NamespaceName $Namespace -LabelSelector 'app=api'
    if ($apiNodes.Count -gt 0) {
        $observed['api_nodes'] = @($apiNodes)
    }

    if ($observed['k6_node'] -and $apiNodes.Count -gt 0) {
        $observed['k6_colocated_with_api'] = ($apiNodes -contains $observed['k6_node'])
    }

    $metadata['api_resources_observed'] = $observed

    $observedSummary = "$($observed.cpu_request) cpu / $($observed.memory_request) request, $($observed.cpu_limit) cpu / $($observed.memory_limit) limit, $($observed.qos_class), $($observed.replicas_ready)/$($observed.replicas_desired) ready"
    Write-Host "API as measured     : $observedSummary" -ForegroundColor Cyan

    if (-not $TestOnly -and $metadata['api_resources_requested']) {
        $mismatches = @()
        foreach ($field in @('cpu_request', 'cpu_limit', 'memory_request', 'memory_limit')) {
            $requestedValue = "$($metadata['api_resources_requested'][$field])"
            if ($requestedValue -ne "$($observed[$field])") {
                $mismatches += "  $field : requested '$requestedValue', running '$($observed[$field])'"
            }
        }

        $metadata['api_resources_match_requested'] = ($mismatches.Count -eq 0)

        if ($mismatches.Count -gt 0) {
            Write-Warning ("The resources this run asked for are not the resources the API is running with:`n" +
                ($mismatches -join "`n") +
                "`nThe summary describes the deployment above, not the request. Re-run without -TestOnly to apply the request.")
        }
    }

    # The README's generator check used to be a manual `kubectl get pod -o wide` step.
    # On a single-node cluster the Job's anti-affinity is ignored, and the two pods then
    # share CPU and memory: the run measures contention as well as the API.
    if ($observed['k6_colocated_with_api'] -eq $true) {
        Write-Warning ("The k6 pod and the API pod are both on node '$($observed['k6_node'])' - they compete for " +
            'CPU and memory, so this run measures contention as well as the API itself.')
    }
}

if ($podName) {
    # The log was already collected by Invoke-PerfTestK6Job, which is also what read the
    # pod's exit code: k6's own exit code is the only place a crossed threshold is
    # visible (99), and it must not be lost between the Job and the artefact.
    Write-Host "  pod           : $podName"
}
else {
    throw "No pod was found for Job $jobName, so there is no log to collect."
}

if ($DeleteJobAfterRun) {
    Invoke-Kubectl -Arguments @('delete', 'job', $jobName, '-n', $Namespace, '--ignore-not-found=true') | Out-Null
}
else {
    Write-Host "Job and pod left in place for inspection. Remove them with: kubectl delete job $jobName -n $Namespace" -ForegroundColor DarkGray
}

Write-PerfTestResult `
    -LogPath $logPath `
    -SummaryPath $summaryPath `
    -MetaPath $metaPath `
    -RunDirectory $runDirectory `
    -Metadata $metadata `
    -ExitCode $exitCode `
    -ExitReason $exitReason `
    -JobOutcome "$($jobResult.Outcome)" | Out-Null

Write-Host ''
Write-Host 'Compare against the last accepted baseline with:' -ForegroundColor Cyan
Write-Host "  ./scripts/compare-summary.ps1 -Current `"$summaryPath`" -Baseline `"./baselines/$TestType.json`"" -ForegroundColor DarkGray

exit $exitCode
