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

.PARAMETER ApiPath
    Optional. Path to the API project, if you want this script to build the image
    first. Prefer letting the app's own CI publish an image and passing -Image.

.PARAMETER EnvVars
    Scenario knobs in NAME=value form, e.g. -EnvVars TARGET_VUS=200,HOLD_DURATION=30m.

.EXAMPLE
    ./scripts/deploy-and-test.ps1 http://api-service:8080/api/health smoke

.EXAMPLE
    ./scripts/deploy-and-test.ps1 -TargetUrl http://api-service:8080/api/orders `
        -TestType load -Image exchangeportal-finance-api:$(git rev-parse --short HEAD) `
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

    [string] $Image = 'exchangeportal-finance-api:local',
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

    [int] $TimeoutSeconds = 1800,
    [string[]] $EnvVars = @(),

    [string] $ApiPath,
    [string] $BuildEnv = 'Release',

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

    $image = Split-PerfTestImage -Reference $ImageReference

    # Quoted deliberately. Unquoted, a purely numeric tag is emitted as
    # `newTag: 1`, YAML parses that as an integer, and kustomize rejects the whole
    # overlay with:
    #
    #   invalid Kustomization: json: cannot unmarshal number into Go struct field
    #   Image.images.newTag of type string
    #
    # Numeric tags are perfectly legal in Docker - CI build numbers are the usual
    # source of them - so the runner has to survive them rather than making the user
    # rename their image.
    $imageEntry = @("    newName: `"$($image.Name)`"")
    if ($image.Digest) {
        $imageEntry += "    digest: `"$($image.Digest)`""
    }
    else {
        $imageEntry += "    newTag: `"$($image.Tag)`""
    }

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
        'images:'
        '  - name: your-aspnet-api'
    ) + $imageEntry + @(
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
        [string] $PrometheusWriteUrl = ''
    )

    $envLines = @(
        '            - name: TARGET_URL'
        "              value: `"$Url`""
    )
    foreach ($name in ($ScenarioEnv.Keys | Sort-Object)) {
        $envLines += "            - name: $name"
        $envLines += "              value: `"$($ScenarioEnv[$name])`""
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
        '      containers:'
        '        - name: k6'
        "          image: $GeneratorImage"
        "          imagePullPolicy: $PullPolicy"
        # --tag test_type is set here rather than in the scenario's options.tags:
        # measured on the compose stack, a tag set inside options.tags does not
        # reach a metrics backend, while the same tag passed on the CLI does.
        '          command: ["k6", "run", "--tag", "test_type=' + $TestType + '", "/scripts/' + $Script + '"]'
        '          env:'
    ) + $envLines + @(
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
    <# Load locally-built images into kind/minikube, where the docker daemon is not shared. #>
    param([Parameter(Mandatory = $true)][string] $Context)

    foreach ($candidate in @($Image, $K6Image)) {
        if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { return }

        $previous = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            & docker image inspect $candidate *> $null
            $exists = ($LASTEXITCODE -eq 0)
        }
        finally {
            $ErrorActionPreference = $previous
        }
        if (-not $exists) { continue }

        if ($Context -like 'kind-*') {
            if (-not (Get-Command kind -ErrorAction SilentlyContinue)) {
                Write-Warning "kind context detected but the 'kind' CLI is not on PATH. Load it manually: kind load docker-image $candidate"
                continue
            }
            Write-Host "Loading $candidate into kind..." -ForegroundColor Cyan
            Invoke-Checked 'kind' @('load', 'docker-image', $candidate)
        }
        elseif ($Context -like 'minikube*') {
            if (-not (Get-Command minikube -ErrorAction SilentlyContinue)) {
                Write-Warning "minikube context detected but the 'minikube' CLI is not on PATH. Load it manually: minikube image load $candidate"
                continue
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
            Write-Host "Loading $candidate into minikube..." -ForegroundColor Cyan
            Invoke-Checked 'minikube' @('image', 'load', $candidate)
        }
    }
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
        -PrometheusWriteUrl $PrometheusWriteUrl | Out-Null

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

    $revision = Get-PerfTestGitRevision
    $metadata = @{
        schema              = 'perftest.run/v1'
        runner              = 'scripts/deploy-and-test.ps1'
        test_type           = $TestType
        target_url          = $TargetUrl
        scenario            = $scenarioFile
        namespace           = $Namespace
        api_image           = $Image
        k6_image            = $K6Image
        image_pull_policy   = $ImagePullPolicy
        replicas            = $Replicas
        runtime_environment = $RuntimeEnvironment
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

    if ($ApiPath) {
        # Legacy path. Prefer -Image with an image your CI published: this build
        # knows about another repository's directory layout, which is on the list
        # to remove (see README, P1 item 8).
        $apiPath = (Resolve-Path $ApiPath).Path
        $apiDockerfile = Join-Path $apiPath 'Dockerfile'
        if (-not (Test-Path $apiDockerfile -PathType Leaf)) {
            throw "Dockerfile was not found at $apiDockerfile."
        }

        $buildContext = (Get-Item (Join-Path $apiPath '..\..\..')).FullName
        $rootNugetConfig = Join-Path $buildContext 'nuget.config'
        $newCoreNugetConfig = Join-Path $buildContext 'NewCore\nuget.config'
        $tempDockerfile = $null

        try {
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

            Write-Host "Building API image $Image from $apiPath..." -ForegroundColor Cyan
            Invoke-Checked 'docker' @('build', '-f', $dockerfileForBuild, '--build-arg', "ENVIRONMENT=$BuildEnv", '-t', $Image, $buildContext)
            $builtImages = $true
        }
        finally {
            if ($tempDockerfile -and (Test-Path $tempDockerfile)) {
                Remove-Item $tempDockerfile -Force
            }
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

    Write-Host 'Deploying the API under test...' -ForegroundColor Cyan
    Invoke-Kubectl -Arguments @('apply', '-k', $overlayDirectory) | Out-Null

    # A reused tag plus a non-Always pull policy means the node can keep serving
    # the previous build, with no rollout triggered because the spec never changed.
    # Restart so the run is guaranteed to exercise what was just built.
    Invoke-Kubectl -Arguments @('rollout', 'restart', 'deployment/api-deployment', '-n', $Namespace) | Out-Null

    Write-Host 'Waiting for the API to become ready...' -ForegroundColor Cyan
    Invoke-Kubectl -Arguments @('rollout', 'status', 'deployment/api-deployment', '-n', $Namespace, '--timeout=300s') | Out-Null

    if ($DeployOnly) {
        Write-Host 'Deployment is ready (-DeployOnly).' -ForegroundColor Green
        exit 0
    }
}
elseif ($DeployOnly) {
    throw '-DeployOnly cannot be combined with -TestOnly.'
}

# ---------------------------------------------------------------------------
# Run the test.
# ---------------------------------------------------------------------------
$jobManifestPath = Join-Path $runDirectory 'k6-job.yaml'
New-K6JobManifest `
    -Path $jobManifestPath `
    -JobName $jobName `
    -NamespaceName $Namespace `
    -Type $TestType `
    -Script $scenarioFile `
    -Url $TargetUrl `
    -GeneratorImage $K6Image `
    -PullPolicy $ImagePullPolicy `
    -CpuRequest $K6CpuRequest `
    -ScenarioEnv $testEnv `
    -PrometheusWriteUrl $PrometheusWriteUrl | Out-Null

Write-Host "Running the $TestType test against $TargetUrl ..." -ForegroundColor Cyan
Write-Host "  Job manifest: $jobManifestPath"
Write-Host "  Follow live:  kubectl logs -n $Namespace -l job-name=$jobName -f"

Invoke-Kubectl -Arguments @('delete', 'job', $jobName, '-n', $Namespace, '--ignore-not-found=true') | Out-Null
Invoke-Kubectl -Arguments @('apply', '-f', $jobManifestPath) | Out-Null

$waitStarted = Get-Date
$outcome = Wait-K6Job -JobName $jobName -NamespaceName $Namespace -TimeoutSec $TimeoutSeconds -Context $kubectlContext
$elapsed = [int]((Get-Date) - $waitStarted).TotalSeconds
Write-Host "Job $jobName finished as $($outcome.Outcome) after ${elapsed}s." -ForegroundColor Cyan

$pod = Get-JobPods -JobName $jobName -NamespaceName $Namespace | Select-Object -First 1
$podName = ''
$exitCode = 0
$exitReason = ''

if ($pod) {
    $podName = $pod.metadata.name
    $metadata['pod_name'] = $podName
    $containerStatus = @($pod.status.containerStatuses) | Select-Object -First 1
    if ($containerStatus -and $containerStatus.state -and $containerStatus.state.terminated) {
        $exitCode = [int]$containerStatus.state.terminated.exitCode
        $exitReason = "$($containerStatus.state.terminated.reason)"
    }
}

if ($podName) {
    $logLines = Invoke-Kubectl -Arguments @('logs', $podName, '-n', $Namespace) -AllowFailure
    Write-Utf8NoBom -Path $logPath -Content (($logLines -join "`n")) | Out-Null
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
    -JobOutcome "$($outcome.Outcome)" | Out-Null

Write-Host ''
Write-Host 'Compare against the last accepted baseline with:' -ForegroundColor Cyan
Write-Host "  ./scripts/compare-summary.ps1 -Current `"$summaryPath`" -Baseline `"./baselines/$TestType.json`"" -ForegroundColor DarkGray

exit $exitCode
