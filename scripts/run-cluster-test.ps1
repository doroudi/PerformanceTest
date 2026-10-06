<#
.SYNOPSIS
    The front door for a CLUSTER run: build the API image, deploy it to Kubernetes, and
    run one k6 scenario against it as a Job.

.DESCRIPTION
    This is the cluster counterpart of k6/run-test.ps1: the same scenarios (from
    k6/scripts, baked into the k6 image), the same artefacts (results/<testid>/ with
    k6.log, summary.json, meta.json and the manifests that were applied), the same
    Grafana dashboard - but the generator runs as a Job inside the cluster and the API
    runs under real CPU and memory limits, which is the only way to measure a pod.

    It deliberately reimplements none of that. Everything goes through
    scripts/deploy-and-test.ps1, which stays non-interactive so the bash wrappers and CI
    keep working. This script adds what a person needs and a pipeline does not:

      * prompts for what you would otherwise have to look up - which Dockerfile or
        publish folder, which test type, which endpoint;
      * reads the login account from k6\.env and puts the credential-shaped values into a
        Kubernetes Secret, so no password is written into the archived Job manifest
        (results/<run>/k6-job.yaml is the exact manifest that was applied, so anything
        passed as -EnvVars is an artefact);
      * deploys the in-cluster Prometheus/Grafana and prints a Grafana link pinned to this
        run's window and testid;
      * -DryRun prints the whole plan - commands, image, resources, the exact command
        line - and touches neither Docker nor the cluster.

    Read the plan before the first real run: it names the image, the resources and the
    target, and those three are the experiment.

.PARAMETER Dockerfile
    The Dockerfile to build the API image from. Omit it and the script looks for a
    `dotnet publish` output instead (see -PublishDirectory), which is what this kit's own
    k8s/app/Dockerfile expects.

.PARAMETER BuildContext
    The directory to build from. Defaults to the Dockerfile's own directory, which is the
    only default that can work for a self-contained Dockerfile. A Dockerfile that copies
    from the repository root needs this explicitly, and the runner warns by name when a
    COPY source is not in the context it was given.

.PARAMETER PublishDirectory
    A folder produced by `dotnet publish` on the host, built with k8s/app/Dockerfile.

    That image is runtime-only (no SDK, no NuGet cache, no source) and its build never
    sees a private feed's credentials, which is why it is the recommended way to get a
    .NET API into the cluster. The assembly to start is found by looking for
    *.runtimeconfig.json in the folder and passed as APP_DLL, so nothing needs to be
    hard-coded per application.

.PARAMETER BuildArg
    Extra --build-arg values as NAME=value. APP_DLL is added automatically in
    -PublishDirectory mode.

.PARAMETER Image
    Image reference to build and deploy. Defaults to a sanitised name derived from the
    application, tagged with the current UTC time, because a reused tag can be served
    from a node's image cache - which means you measure the previous build.

.PARAMETER TestType
    smoke | load | stress | soak | spike | rate | journey - whichever scenarios exist in
    k6/scripts. Prompted for, with the available list, when omitted.

.PARAMETER TargetUrl
    The endpoint to exercise, as seen from INSIDE the cluster: the Service name, not
    localhost. Defaults to http://api-service:8080 plus -TargetPath.

.PARAMETER TargetPath
    The path to append to the default in-cluster base URL, e.g.
    /api/new-core/requests/active. Ignored for the journey type, which brings its own
    step paths and needs the base URL only.

.PARAMETER EnvFile
    The KEY=value file to read the login details and scenario knobs from. Defaults to
    k6\.env, then <repo>\.env.

.PARAMETER EnvVars
    Extra scenario knobs, NAME=value, comma separated. These are recorded in meta.json
    and in the archived Job manifest, so keep credentials out of them - that is what the
    Secret is for.

.PARAMETER Namespace
    Namespace for the API, the k6 Job and the credentials Secret. Default perf-test.

.PARAMETER CredentialsSecret
    Name of the Secret that carries the credential-shaped values to the k6 pod. It is
    created (or updated) in -Namespace from the environment file. Default
    perf-test-credentials.

.PARAMETER SkipDeploy
    Do not build or deploy: run against whatever is already in the cluster (-TestOnly on
    the runner). meta.json then records the resources that were observed running, not
    the ones on this command line.

.PARAMETER SkipBuild
    Deploy the image named by -Image without building it: for an image your CI published.

.PARAMETER SkipPreflight
    Skip the 1-VU smoke run that proves the target answers from inside the cluster before
    the real profile starts.

.PARAMETER SkipObservability
    Do not deploy the in-cluster Prometheus/Grafana. Metrics (and the Grafana link) are
    then unavailable unless -PrometheusWriteUrl points at a stack you run yourself.

.PARAMETER AllowProduction
    A target whose host name looks like production is refused: this script logs in as a
    real user and exercises real endpoints. Override only if that is genuinely intended.

.PARAMETER NonInteractive
    Never prompt. Anything not supplied as a parameter is an error. This is what makes
    the script usable from a pipeline, and it is how the -DryRun path is tested.

.PARAMETER DryRun
    Print the plan and exit without touching Docker or the cluster.

.EXAMPLE
    # The fully interactive path.
    pwsh -File scripts/run-cluster-test.ps1

.EXAMPLE
    # Nothing but the endpoint: everything else comes from k6\.env and the defaults.
    pwsh -File scripts/run-cluster-test.ps1 -TestType load -TargetPath /api/new-core/wallets

.EXAMPLE
    # Show me exactly what you would do, and do not do it.
    pwsh -File scripts/run-cluster-test.ps1 -TestType journey -DryRun

.EXAMPLE
    # A 4 GiB pod, 2 CPUs, the publish folder that is already on disk.
    pwsh -File scripts/run-cluster-test.ps1 `
        -TestType stress -TargetPath /api/new-core/requests/active `
        -PublishDirectory .build/finance-api `
        -CpuRequest 2 -CpuLimit 2 -MemoryRequest 4Gi -MemoryLimit 4Gi
#>
[CmdletBinding()]
param(
    [string] $Dockerfile,
    [string] $BuildContext,
    [string] $PublishDirectory,
    [string[]] $BuildArg = @(),
    [string] $Image,

    [string] $TestType,
    [string] $TargetUrl,
    [string] $TargetPath,

    # The journey's load SHAPE: steady (default) | load | stress | spike. Only meaningful for
    # -TestType journey; the single-endpoint types have their own profile baked in
    # (stress-test.js is stepped, load-test.js ramps, and so on).
    [ValidateSet('steady', 'load', 'stress', 'spike', 'rate', 'rate-ramp')]
    [string] $JourneyProfile = '',

    [string] $EnvFile,
    [string[]] $EnvVars = @(),

    # A JSON file of test accounts, one per virtual user:
    #
    #   [{ "username": "a@example.com", "password": "..." }, ...]
    #
    # Omit it and k6\users.json is used when it exists. The pool is put into the
    # credentials Secret as JOURNEY_USERS_JSON, so it reaches the k6 Job without ever
    # appearing in the archived Job manifest - and each VU then runs the journey as its own
    # account instead of all of them sharing one.
    [string] $UsersFile,

    [string] $Namespace = 'perf-test',
    [string] $CredentialsSecret = 'perf-test-credentials',
    [string] $ApiDll,

    [int] $Replicas = 1,
    [string] $CpuRequest = '250m',
    [string] $CpuLimit = '500m',
    [string] $MemoryRequest = '256Mi',
    [string] $MemoryLimit = '512Mi',

    [string] $K6Image = 'k6-custom:local',
    [string] $PrometheusWriteUrl = '',

    [switch] $SkipDeploy,
    [switch] $SkipBuild,
    [switch] $SkipPreflight,
    [switch] $SkipObservability,
    [switch] $DeleteJobAfterRun,
    [switch] $AllowProduction,
    [switch] $NonInteractive,
    [switch] $DryRun
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\PerfTest.psm1') -Force

$repoRoot = Get-PerfTestRepoRoot
$scenariosDirectory = Join-Path $repoRoot 'k6\scripts'
$runnerScript = Join-Path $PSScriptRoot 'deploy-and-test.ps1'
$defaultTargetBase = 'http://api-service:8080'
$redactedMarker = '***REDACTED***'

# In-cluster Grafana is a NodePort (k8s/observability/grafana.yaml). A NodePort answers on
# the NODE's network, not on the host's loopback: on Docker Desktop's built-in Kubernetes
# 127.0.0.1:30030 works, on minikube (nodes on 192.168.49.0/24 inside a VM) and kind it
# refuses the connection. Which one this is is not something to guess at, so the port is
# probed and the link is built for the route that actually answers - printing a dead link
# makes a working Grafana look broken.
$grafanaNodePort = 30030
# Free, and specifically NOT the port the compose stack publishes its own Grafana on:
# forwarding in-cluster Grafana onto the compose one's port shows a dashboard that queries
# a different Prometheus and reports "No data" for a cluster run.
$grafanaLocalPort = Get-PerfTestFreeLocalPort -Candidate @(3000, 3001, 3002, 3003)
$dashboardUid = 'k6-load-test'

function Read-Setting {
    <#
    One value, from the command line first, then a prompt.

    -NonInteractive turns a missing value into an error rather than a question, which is
    what lets this script run unattended - and what makes the -DryRun path testable.
    #>
    param(
        [Parameter(Mandatory = $true)][string] $Prompt,
        [string] $Value = '',
        [string] $Default = '',
        [switch] $Required
    )

    if (-not [string]::IsNullOrWhiteSpace($Value)) { return $Value.Trim() }

    if ($NonInteractive) {
        if (-not [string]::IsNullOrWhiteSpace($Default)) { return $Default }
        throw "-NonInteractive was specified but '$Prompt' was not supplied as a parameter."
    }

    $suffix = if ($Default) { " [$Default]" } else { '' }
    $answer = (Read-Host "$Prompt$suffix").Trim()
    if ([string]::IsNullOrWhiteSpace($answer)) { $answer = $Default }

    if ($Required -and [string]::IsNullOrWhiteSpace($answer)) {
        throw "No value given for '$Prompt'."
    }

    return $answer
}

function Read-TestTypeChoice {
    <# A numbered menu, so the available scenarios are discovered rather than remembered. #>
    param([Parameter(Mandatory = $true)][string[]] $Available)

    Write-Host 'Which test?' -ForegroundColor Cyan
    for ($index = 0; $index -lt $Available.Count; $index += 1) {
        Write-Host ('  {0}) {1}' -f ($index + 1), $Available[$index])
    }

    while ($true) {
        $answer = (Read-Host ("Test type [1-{0}]" -f $Available.Count)).Trim()
        if ($answer -match '^\d+$') {
            $position = [int]$answer
            if ($position -ge 1 -and $position -le $Available.Count) { return $Available[$position - 1] }
        }
        if ($Available -contains $answer) { return $answer }
        Write-Warning ("Not one of: {0}. Enter a number, or the name." -f ($Available -join ', '))
    }
}

function Get-PublishFolder {
    <#
    Find a `dotnet publish` output under a directory.

    A publish folder is identified by its *.runtimeconfig.json at the top level, which is
    also what names the assembly to start - so finding the folder and finding APP_DLL are
    the same question, answered once.
    #>
    param([Parameter(Mandatory = $true)][string] $Root)

    $folders = @()

    # The root may itself be a publish folder: check it before looking inside.
    $rootConfig = @(Get-ChildItem -Path $Root -Filter '*.runtimeconfig.json' -File -ErrorAction SilentlyContinue)
    if ($rootConfig.Count -gt 0) {
        return (New-PublishFolderInfo -Directory (Resolve-Path $Root).Path -ConfigFile $rootConfig[0])
    }

    foreach ($child in @(Get-ChildItem -Path $Root -Directory -ErrorAction SilentlyContinue)) {
        $config = @(Get-ChildItem -Path $child.FullName -Filter '*.runtimeconfig.json' -File -ErrorAction SilentlyContinue | Select-Object -First 1)
        if ($config.Count -gt 0) {
            $folders += (New-PublishFolderInfo -Directory $child.FullName -ConfigFile $config[0])
        }
    }

    # Plain array, not ", $folders": the caller wraps this in @(...), and a wrapped array
    # would come back as a single element that IS the array - so one found folder would
    # look like a folder whose properties are arrays.
    return $folders
}

function New-PublishFolderInfo {
    <# The publish folder, and the assembly its runtimeconfig names. #>
    param(
        [Parameter(Mandatory = $true)][string] $Directory,
        [Parameter(Mandatory = $true)][System.IO.FileInfo] $ConfigFile
    )

    # Strip BOTH extensions. [System.IO.Path]::GetFileNameWithoutExtension removes only
    # the last one, which turns "My.App.runtimeconfig.json" into "My.App.runtimeconfig" -
    # an assembly name that does not exist, so the container would start with
    # APP_DLL=<something>.runtimeconfig.dll and fail with "assembly not found".
    $baseName = $ConfigFile.Name -replace '\.runtimeconfig\.json$', ''
    if ($baseName -eq $ConfigFile.Name) {
        $baseName = [System.IO.Path]::GetFileNameWithoutExtension($ConfigFile.Name)
    }
    $dllName = "$baseName.dll"

    return [pscustomobject]@{
        Directory  = $Directory
        DllName    = $dllName
        DllPresent = (Test-Path (Join-Path $Directory $dllName) -PathType Leaf)
    }
}

function New-CredentialsSecretText {
    <#
    Build the Secret manifest for the credential-shaped values.

    Kept as its own function, returning text, for two reasons: it can be inspected
    without a cluster (and is, in the tests), and it keeps the real values out of every
    code path that prints something - the plan lists KEY NAMES only.

    Values are emitted as JSON strings. A password may contain ':', '#', quotes or a
    leading '*', all of which a bare YAML scalar mangles, and JSON strings are valid YAML
    scalars.
    #>
    param(
        [Parameter(Mandatory = $true)][hashtable] $Values,
        [Parameter(Mandatory = $true)][string] $Name,
        [Parameter(Mandatory = $true)][string] $NamespaceName
    )

    $lines = @(
        'apiVersion: v1'
        'kind: Secret'
        'type: Opaque'
        'metadata:'
        "  name: $Name"
        "  namespace: $NamespaceName"
        'stringData:'
    )

    foreach ($key in ($Values.Keys | Sort-Object)) {
        $lines += ('  {0}: {1}' -f $key, (ConvertTo-Json -InputObject "$($Values[$key])" -Compress))
    }

    return ($lines -join "`n")
}

function Format-PlanArguments {
    <# Render a parameter table as an equivalent command line, for the plan. #>
    param([Parameter(Mandatory = $true)][hashtable] $Parameters)

    $parts = @('pwsh -File scripts/deploy-and-test.ps1')

    foreach ($key in ($Parameters.Keys | Sort-Object)) {
        $value = $Parameters[$key]

        if ($value -is [bool]) {
            if ($value) { $parts += "-$key" }
            continue
        }
        if ($value -is [array]) {
            $parts += ('-{0} {1}' -f $key, ($value -join ','))
            continue
        }

        $parts += ('-{0} "{1}"' -f $key, $value)
    }

    return ($parts -join ' ')
}

function Start-GrafanaForward {
    <#
    Make the in-cluster Grafana reachable from this machine, rather than telling the user to
    do it.

    A NodePort is not published on the host's loopback on minikube or kind, so the link this
    wizard prints only works if a `kubectl port-forward` exists first. Printing the link
    anyway - with the command underneath, as a note - produced exactly the wrong outcome: a
    URL that refuses to connect in a browser, which reads as "Grafana is broken" when
    Grafana is healthy and serving the dashboard. The fix is not a better-worded note.

    Returns the port that answers, with the process id when this call started it, or $null
    when no route could be established - in which case the caller must not print a link.
    #>
    param(
        [int[]] $Candidate = @(3001, 3002, 3003),
        [int] $RemotePort = 3000,
        [string] $NamespaceName = 'perf-observability',
        [string] $DashboardUid = 'k6-load-test'
    )

    if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) { return $null }

    # A previous run may have left one running - reuse it rather than stacking another
    # forward on every invocation. Only ports above the compose stack's own 3000 are
    # considered, and the port has to be serving THIS dashboard: a listening port that is
    # something else entirely would be worse than no link at all.
    foreach ($port in $Candidate) {
        if (-not (Test-PerfTestTcpEndpoint -Port $port)) { continue }

        try {
            $probe = Invoke-WebRequest -Uri "http://127.0.0.1:$port/api/dashboards/uid/$DashboardUid" -TimeoutSec 5 -SkipHttpErrorCheck
            if ([int]$probe.StatusCode -eq 200 -and $probe.Content -match '"dashboard"') {
                return [pscustomobject]@{ Port = $port; ProcessId = $null; Reused = $true }
            }
        }
        catch {
            # Not a Grafana we can use; keep looking.
        }
    }

    foreach ($port in $Candidate) {
        if (Test-PerfTestTcpEndpoint -Port $port) { continue }

        # Supervised, not a bare `kubectl port-forward`. A single forward dies when the pod
        # behind the Service is replaced - which a dashboard change does - or when the
        # stream to the API server drops, and either way the browser then shows a connection
        # error for a Grafana that is healthy. scripts/expose-observability.ps1 runs kubectl
        # in a loop on the same port, so the URL keeps working across that.
        $supervisor = Join-Path $PSScriptRoot 'expose-observability.ps1'
        if (-not (Test-Path $supervisor -PathType Leaf)) { return $null }

        $startArguments = @{
            FilePath     = 'pwsh'
            ArgumentList = @('-NoProfile', '-File', $supervisor, '-Service', 'grafana', '-LocalPort', "$port", '-Namespace', $NamespaceName)
            PassThru     = $true
        }
        # Hidden so the supervisor's "Forwarding from ..." chatter does not interleave with
        # the run's output. Windows only; elsewhere Start-Process detaches without a console.
        if ($IsWindows) { $startArguments['WindowStyle'] = 'Hidden' }

        $forwardProcess = $null
        try {
            $forwardProcess = Start-Process @startArguments
        }
        catch {
            return $null
        }

        $deadline = (Get-Date).AddSeconds(15)
        while ((Get-Date) -lt $deadline) {
            if (Test-PerfTestTcpEndpoint -Port $port) {
                # Detached on purpose: the link is most useful after the run has finished, so
                # the forward must outlive this script.
                return [pscustomobject]@{ Port = $port; ProcessId = $forwardProcess.Id; Reused = $false }
            }
            if ($forwardProcess.HasExited) { break }
            Start-Sleep -Milliseconds 500
        }

        if ($forwardProcess -and -not $forwardProcess.HasExited) { $forwardProcess.Kill() }
    }

    return $null
}

function Test-IsClusterLocalName {
    <#
    True for a name the CLUSTER serves.

    These must keep resolving through the cluster's own DNS and the Service: pinning
    `api-service` to one address would send every request of a multi-replica run to a
    single endpoint, and the run would then measure one pod while claiming to measure
    the deployment.
    #>
    param([Parameter(Mandatory = $true)][string] $HostName)

    if ($HostName -in @('localhost', '127.0.0.1', 'api-service')) { return $true }
    if ($HostName -like '*.svc' -or $HostName -like '*.svc.cluster.local' -or $HostName -like '*.local') { return $true }

    return $false
}

function Resolve-InputPath {
    <#
    A path from the command line, made absolute.

    A relative path is tried against the REPOSITORY root before the current directory:
    every example in this kit is written from the repository root, and
    `-PublishDirectory .build/finance-api` should not build a different folder - or
    nothing at all - because the caller happened to be somewhere else.
    #>
    param([Parameter(Mandatory = $true)][string] $Path)

    if ([System.IO.Path]::IsPathRooted($Path)) { return $Path }

    $fromRepo = Join-Path $repoRoot $Path
    if (Test-Path $fromRepo) { return (Resolve-Path $fromRepo).Path }

    return $Path
}

# ---------------------------------------------------------------------------
# 1. What to run.
# ---------------------------------------------------------------------------
$availableTypes = @(Get-PerfTestTypes -ScenariosDirectory $scenariosDirectory)

$resolvedTestType = $TestType
if ([string]::IsNullOrWhiteSpace($resolvedTestType)) {
    if ($NonInteractive) {
        throw ("-TestType is required with -NonInteractive. Available: {0}." -f ($availableTypes -join ', '))
    }
    $resolvedTestType = Read-TestTypeChoice -Available $availableTypes
}

# Resolve-PerfTestScenario is the single source of truth for "which test types exist", so
# a typo fails here with the real list rather than as a missing file inside a container.
$scenarioFile = Split-Path -Leaf (Resolve-PerfTestScenario -TestType $resolvedTestType -ScenariosDirectory $scenariosDirectory)
$isJourney = ($resolvedTestType -eq 'journey')

if ($JourneyProfile) {
    if (-not $isJourney) {
        throw ("-JourneyProfile only applies to -TestType journey (it selects the load shape of the multi-step " +
            "scenario). '$resolvedTestType' has its own shape: stress-test.js is stepped, load-test.js ramps, " +
            'spike-test.js spikes, rate-test.js offers a fixed rate.')
    }
}

# ---------------------------------------------------------------------------
# 2. How to produce the API image.
# ---------------------------------------------------------------------------
$resolvedDockerfile = ''
$resolvedBuildContext = ''
$resolvedPublishDirectory = ''
$resolvedApiDll = $ApiDll
$buildArguments = @($BuildArg)

if (-not $SkipDeploy -and -not $SkipBuild) {
    if ($Dockerfile) {
        $resolvedDockerfile = Resolve-InputPath -Path $Dockerfile
        if (-not (Test-Path $resolvedDockerfile -PathType Leaf)) { throw "-Dockerfile was not found: $Dockerfile" }
        $resolvedDockerfile = (Resolve-Path $resolvedDockerfile).Path
        $resolvedBuildContext = if ($BuildContext) {
            $contextPath = Resolve-InputPath -Path $BuildContext
            if (-not (Test-Path $contextPath -PathType Container)) { throw "-BuildContext is not a directory: $BuildContext" }
            (Resolve-Path $contextPath).Path
        }
        else {
            Split-Path -Parent $resolvedDockerfile
        }
    }
    else {
        $publishRoot = if ($PublishDirectory) { Resolve-InputPath -Path $PublishDirectory } else { Join-Path $repoRoot '.build' }

        if ($PublishDirectory) {
            if (-not (Test-Path $publishRoot -PathType Container)) { throw "-PublishDirectory was not found: $publishRoot" }
            $folders = @(Get-PublishFolder -Root $publishRoot)
        }
        else {
            $folders = @()
            if (Test-Path $publishRoot -PathType Container) { $folders = @(Get-PublishFolder -Root $publishRoot) }
        }

        if ($folders.Count -eq 0) {
            # Nothing to publish-build from. Ask for a Dockerfile rather than failing:
            # plenty of applications ship a normal multi-stage Dockerfile, and that is a
            # perfectly good answer to this question.
            if ($NonInteractive) {
                throw ("No `dotnet publish` output was found under '$publishRoot', and no -Dockerfile was given. " +
                    'Pass -Dockerfile (with -BuildContext if it copies from outside its own directory), or -PublishDirectory.')
            }

            Write-Host "No publish output found under $publishRoot." -ForegroundColor DarkYellow
            $answer = Read-Setting -Prompt 'Path to a Dockerfile to build instead' -Required
            if (-not (Test-Path $answer -PathType Leaf)) { throw "Dockerfile was not found: $answer" }
            $resolvedDockerfile = (Resolve-Path $answer).Path
            $resolvedBuildContext = Split-Path -Parent $resolvedDockerfile
        }
        else {
            if ($folders.Count -gt 1 -and -not $PublishDirectory) {
                Write-Host 'Publish folders found:' -ForegroundColor Cyan
                for ($index = 0; $index -lt $folders.Count; $index += 1) {
                    Write-Host ('  {0}) {1}  ({2})' -f ($index + 1), $folders[$index].Directory, $folders[$index].DllName)
                }
                $choice = Read-Setting -Prompt ("Which one [1-{0}]" -f $folders.Count) -Default '1'
                $position = 1
                if ($choice -match '^\d+$' -and [int]$choice -ge 1 -and [int]$choice -le $folders.Count) { $position = [int]$choice }
                $folders = @($folders[$position - 1])
            }
            elseif ($folders.Count -gt 1) {
                throw ("'$publishRoot' contains {0} publish folders ({1}). Name the one to use with -PublishDirectory." -f `
                        $folders.Count, (($folders | ForEach-Object { Split-Path -Leaf $_.Directory }) -join ', '))
            }

            $resolvedPublishDirectory = $folders[0].Directory
            $resolvedDockerfile = Join-Path $repoRoot 'k8s\app\Dockerfile'
            $resolvedBuildContext = $resolvedPublishDirectory

            if (-not $resolvedApiDll) { $resolvedApiDll = $folders[0].DllName }

            if (-not $folders[0].DllPresent) {
                throw ("The publish folder '$resolvedPublishDirectory' names its entry point with " +
                    "'$($folders[0].DllName)' but that assembly is not in the folder, so the container would start and " +
                    'immediately fail with "assembly not found". Re-run `dotnet publish` (or pass -ApiDll if the ' +
                    'assembly really is named something else).')
            }

            $buildArguments += "APP_DLL=$resolvedApiDll"
        }
    }
}

# The tag carries the current UTC time by default. A reused tag plus imagePullPolicy
# IfNotPresent is how a node serves the PREVIOUS build with no rollout to notice: the pod
# restarts, the spec never changed, and the numbers belong to an image you already
# replaced.
$resolvedImage = $Image
if (-not $resolvedImage) {
    if ($SkipDeploy) {
        $resolvedImage = ''
    }
    else {
        $imageBase = if ($resolvedApiDll) { $resolvedApiDll } else { 'service-api' }
        $imageBase = ($imageBase -replace '\.dll$', '') -replace '[^A-Za-z0-9._-]', '-'
        $resolvedImage = '{0}:local-{1}' -f $imageBase.ToLowerInvariant(), (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmm')
    }
}

# ---------------------------------------------------------------------------
# 3. What to hit.
#
# Inside the cluster the target is the Service, not localhost and not your machine. The
# default is the one the whole kit deploys (k8s/base/api-service.yaml, port 8080).
# ---------------------------------------------------------------------------
$resolvedTarget = $TargetUrl
if ([string]::IsNullOrWhiteSpace($resolvedTarget)) {
    if ($isJourney) {
        # The journey appends its own step paths to the base URL, so a path here would
        # produce /api/new-core/wallets/api/new-core/... and measure a 404.
        $resolvedTarget = $defaultTargetBase
    }
    else {
        $path = Read-Setting -Prompt 'Endpoint path on the API' -Value $TargetPath -Default '/healthz' -Required
        if (-not $path.StartsWith('/')) { $path = "/$path" }
        $resolvedTarget = $defaultTargetBase + $path
    }
}
elseif ($isJourney) {
    $targetPath = ([System.Uri]$resolvedTarget).AbsolutePath
    if ($targetPath -and $targetPath -ne '/') {
        Write-Warning ("The journey type uses its own step paths, so the path in '$resolvedTarget' is ignored and may corrupt" +
            ' the step URLs. Pass the API base only, and set KYC_STEP_PATH/WALLETS_PATH/REQUESTS_ACTIVE_PATH via -EnvVars if they differ.')
    }
}

if ($resolvedTarget -notmatch '^https?://') {
    throw "TargetUrl must start with http:// or https://, but got '$resolvedTarget'."
}

# The same guard run-journey.ps1 applies, for the same reason: this run logs in as a real
# person and exercises real endpoints.
$targetHost = ([System.Uri]$resolvedTarget).Host
if (-not $AllowProduction -and $targetHost -match '(?i)(^|[.\-])prod(uction)?([.\-]|$)') {
    throw ("Refusing to run against '$targetHost': the host name looks like production, and this test logs in as a" +
        ' real user and exercises real endpoints. Pass -AllowProduction if that is genuinely intended.')
}

$targetsThisCluster = ($targetHost -eq 'api-service' -or $targetHost -like '*.svc*' -or $targetHost -like '*.local')
if (-not $targetsThisCluster -and -not $SkipDeploy) {
    Write-Warning ("The target '$targetHost' is not the in-cluster Service, so the API this run deploys is not what it" +
        ' measures. Pass -SkipDeploy if the deployment is not wanted.')
}

# ---------------------------------------------------------------------------
# 4. Credentials and knobs, from the environment file.
#
# Which values are credentials is not decided here: Protect-PerfTestSecretValues already
# answers it for meta.json, and asking the same question twice is how k6-job.yaml ended
# up with a password in it. Whatever that function masks goes into the Secret instead -
# so the value never reaches an artefact at all, rather than being masked inside one.
# ---------------------------------------------------------------------------
$envFileResult = Import-PerfTestEnvFile -ExplicitPath $EnvFile -SearchPaths @(
    (Join-Path $repoRoot 'k6\.env')
    (Join-Path $repoRoot '.env')
)
$fileEnv = $envFileResult.Values

$secretValues = [ordered]@{}
$knobEntries = @()

if ($fileEnv.Count -gt 0) {
    $masked = Protect-PerfTestSecretValues -Environment $fileEnv

    foreach ($name in ($fileEnv.Keys | Sort-Object)) {
        # The target is decided above, validated and recorded exactly once. A TARGET_URL in
        # the file would be silently ignored by the runner, so it is dropped with a note
        # rather than passed on.
        if ($name -in @('TARGET_URL', 'API_BASE_URL')) {
            Write-Host "Environment file: $name is ignored; the target comes from -TargetUrl/-TargetPath." -ForegroundColor DarkGray
            continue
        }

        # AUTH_MODE describes how the OTHER test types authenticate. The journey logs in
        # once in setup() and reuses the token, so json-login here would add a second,
        # redundant login per VU - which the identity provider sees as a burst of
        # authentications that has nothing to do with the target. run-journey.ps1 forces
        # the same override; this is that decision, made once more for the file's value
        # only, so an explicit -EnvVars AUTH_MODE=... from the command line still wins.
        if ($isJourney -and $name -eq 'AUTH_MODE') {
            Write-Host 'Environment file: AUTH_MODE is ignored for the journey type (it authenticates in setup(); off avoids a login per VU).' -ForegroundColor DarkGray
            continue
        }

        if ("$($masked[$name])" -eq $redactedMarker) {
            $secretValues[$name] = "$($fileEnv[$name])"
        }
        else {
            $knobEntries += "$name=$($fileEnv[$name])"
        }
    }
}

foreach ($entry in $EnvVars) {
    foreach ($part in ("$entry" -split ',')) {
        if ($part.Trim()) { $knobEntries += $part.Trim() }
    }
}

if ($JourneyProfile) {
    $knobEntries = @($knobEntries | Where-Object { $_ -notlike 'JOURNEY_PROFILE=*' })
    $knobEntries += "JOURNEY_PROFILE=$JourneyProfile"
}

# How many VUs the run will actually reach, which depends on the profile: TARGET_VUS is only
# the whole story for a steady or ramping run. Needed below to say whether a credential pool
# is big enough - the peak is what matters, not the starting count.
function Get-KnobNumber {
    param([string] $Name, [int] $Default)

    $entry = @($knobEntries | Where-Object { $_ -like "$Name=*" })
    if ($entry.Count -eq 0) { return $Default }

    $value = 0
    if ([int]::TryParse(($entry[0] -replace "^$Name=", ''), [ref]$value)) { return $value }
    return $Default
}

$peakVus = Get-KnobNumber -Name 'TARGET_VUS' -Default 5
$activeProfile = @($knobEntries | Where-Object { $_ -like 'JOURNEY_PROFILE=*' })
if ($activeProfile.Count -gt 0) {
    $profileName = "$($activeProfile[0] -replace '^JOURNEY_PROFILE=', '')".ToLowerInvariant()
    if ($profileName -eq 'stress') {
        $peakVus = (Get-KnobNumber -Name 'STEP_VUS' -Default 10) * (Get-KnobNumber -Name 'STRESS_STEPS' -Default 4)
    }
    elseif ($profileName -eq 'spike') {
        $peakVus = Get-KnobNumber -Name 'SPIKE_VUS' -Default 50
    }
    elseif ($profileName -eq 'rate' -or $profileName -eq 'rate-ramp') {
        # An arrival-rate run creates as many VUs as it needs to hold the offered rate, up to
        # the ceiling - so the ceiling is the number of accounts a pool has to cover.
        $peakVus = Get-KnobNumber -Name 'MAX_VUS' -Default 400
    }
}

# ---------------------------------------------------------------------------
# A pool of accounts, one per virtual user, from a JSON file.
#
# It goes into the Secret rather than into -EnvVars for two reasons, and both matter here:
# a JSON array is full of commas that the knob parser would split on, and -EnvVars values
# are written verbatim into results/<run>/k6-job.yaml. A pool of thirty passwords belongs
# in neither place.
# ---------------------------------------------------------------------------
$usersFilePath = Resolve-PerfTestUsersFile -ExplicitPath $UsersFile -Environment $fileEnv -SearchPaths @(
    (Join-Path $repoRoot 'k6\users.json')
)

if ($usersFilePath) {
    $usersJson = Read-PerfTestUsersFile -Path $usersFilePath
    $secretValues['JOURNEY_USERS_JSON'] = $usersJson

    $parsedPool = $usersJson | ConvertFrom-Json
    $poolAccounts = if ($parsedPool -is [array]) { @($parsedPool) } elseif ($parsedPool.users) { @($parsedPool.users) } else { @() }

    Write-Host "Accounts    : $($poolAccounts.Count) from $usersFilePath (each VU authenticates as its own)" -ForegroundColor Cyan

    # Say it when the run cannot give every VU its own account: that is precisely the
    # situation the pool exists to avoid, and it is silent otherwise. The comparison is
    # against the PEAK VU count, which for a staged profile is not TARGET_VUS - and for an
    # arrival-rate profile the ceiling is MAX_VUS, which is an upper bound rather than a
    # prediction: what it really needs is the offered rate times how long one journey takes.
    if ($peakVus -gt 0 -and $poolAccounts.Count -lt $peakVus) {
        $reach = if ($activeProfile.Count -gt 0 -and $profileName -in @('rate', 'rate-ramp')) {
            "may need up to $peakVus VUs (about the offered rate x how long one journey takes, capped by MAX_VUS)"
        }
        else {
            "reaches $peakVus VUs"
        }

        Write-Warning ("The run $reach but the pool holds $($poolAccounts.Count) account(s), so accounts will be shared - " +
            'which is what the pool exists to avoid. Add accounts, or lower the peak.')
    }
}

if ($isJourney) {
    # The journey logs in once in setup() and reuses the token. Leaving the generic
    # mechanism on would add a login per VU on top of that, which the identity provider
    # sees as a burst of authentications that has nothing to do with the target.
    if (-not ($knobEntries | Where-Object { $_ -like 'AUTH_MODE=*' })) {
        $knobEntries += 'AUTH_MODE=off'
    }

    if (-not ($knobEntries | Where-Object { $_ -like 'AUTH_MODE=off' })) {
        Write-Warning ("AUTH_MODE is not 'off' for a journey run: every VU will also log in through lib/auth.js on top of" +
            ' the single login in setup(), which measures the identity provider as much as the API.')
    }

    # LOGIN_URL is always needed: a credential pool supplies the ACCOUNTS, not the endpoint
    # they log in against.
    $missingLogin = @()
    if (-not ($knobEntries | Where-Object { $_ -like 'LOGIN_URL=*' }) -and -not $secretValues.Contains('LOGIN_URL')) {
        $missingLogin += 'LOGIN_URL'
    }

    # The single account, however, is only needed when there is no pool. Demanding it as well
    # would block the very setup the pool exists for - and it did: with k6/users.json in place
    # and JOURNEY_USERNAME removed from k6\.env, the scenario was perfectly configured while
    # this check refused to start.
    if (-not $usersFilePath) {
        if (-not ($knobEntries | Where-Object { $_ -like 'JOURNEY_USERNAME=*' }) -and -not $secretValues.Contains('JOURNEY_USERNAME')) {
            $missingLogin += 'JOURNEY_USERNAME'
        }
    }

    if ($missingLogin.Count -gt 0) {
        throw ("The journey type needs {0}. Put them in {1} (copy k6\.env.example to start), or pass them in -EnvVars." -f `
                ($missingLogin -join ', '), $(if ($envFileResult.Path) { $envFileResult.Path } else { 'k6\.env' }))
    }

    # A pool carries the passwords with it, so there is nothing to prompt for and nothing that
    # could end up in an artefact.
    if (-not $usersFilePath -and -not $secretValues.Contains('JOURNEY_PASSWORD') -and -not $secretValues.Contains('AUTH_PASSWORD')) {
        if ($NonInteractive) {
            throw ('No JOURNEY_PASSWORD (or AUTH_PASSWORD) was found and -NonInteractive forbids prompting for it.' +
                ' Add the account to a credential pool (k6\users.json) instead - see -UsersFile.')
        }
        Write-Host 'Password (input is hidden; it goes into the Secret, never into an artefact):' -ForegroundColor Cyan
        $secure = Read-Host -AsSecureString
        if ($secure.Length -eq 0) { throw 'The password is empty.' }
        $secretValues['JOURNEY_PASSWORD'] = [System.Net.NetworkCredential]::new('', $secure).Password
    }
}

# ---------------------------------------------------------------------------
# 5. The plan.
# ---------------------------------------------------------------------------
if ($envFileResult.Path) {
    Write-Host "Environment file: $($envFileResult.Path)" -ForegroundColor Cyan
}
else {
    Write-Host 'Environment file: none found (looked for k6\.env and .env)' -ForegroundColor DarkYellow
}

$writeUrl = $PrometheusWriteUrl
if (-not $writeUrl -and -not $SkipObservability) {
    $writeUrl = 'http://prometheus.perf-observability.svc.cluster.local:9090/api/v1/write'
}

$runnerParameters = [ordered]@{
    TargetUrl = $resolvedTarget
    TestType  = $resolvedTestType
    Namespace = $Namespace
    K6Image   = $K6Image
    Replicas  = $Replicas
}

if ($SkipDeploy) {
    $runnerParameters['TestOnly'] = $true
}
else {
    $runnerParameters['CpuRequest'] = $CpuRequest
    $runnerParameters['CpuLimit'] = $CpuLimit
    $runnerParameters['MemoryRequest'] = $MemoryRequest
    $runnerParameters['MemoryLimit'] = $MemoryLimit
    if ($resolvedImage) { $runnerParameters['Image'] = $resolvedImage }
}

if ($SkipDeploy -or $SkipBuild) {
    # Nothing is built: the image is either already in the cluster (-SkipDeploy) or is
    # named by -Image and pulled by the kubelet (-SkipBuild).
    if (-not $SkipDeploy -and -not $Image) { throw '-SkipBuild needs -Image: without a build, the image reference is the whole input.' }
}
else {
    $runnerParameters['Dockerfile'] = $resolvedDockerfile
    $runnerParameters['BuildContext'] = $resolvedBuildContext
    if ($buildArguments.Count -gt 0) { $runnerParameters['BuildArg'] = @($buildArguments) }
}

if ($knobEntries.Count -gt 0) { $runnerParameters['EnvVars'] = @($knobEntries) }
if ($secretValues.Count -gt 0) { $runnerParameters['CredentialsSecret'] = $CredentialsSecret }

# ---------------------------------------------------------------------------
# Names the k6 pod has to reach that live OUTSIDE the cluster.
#
# A cluster's DNS frequently cannot resolve external names, and both of the interesting
# ones here are external: the identity provider a scenario logs in against, and possibly
# the target itself. Left alone, the generator gets `lookup <host> on <dns>: server
# misbehaving` and every authenticated request fails before it is sent - measured on a
# real minikube, where CoreDNS was timing out against the host's resolver while the same
# name resolved fine from the machine running this script.
#
# So the addresses are resolved HERE and pinned into the Job, and the Job is then
# independent of the cluster resolver. Cluster-local names are skipped: they must keep
# going through the Service, or a multi-replica target would be measured through one IP.
# ---------------------------------------------------------------------------
$resolveHosts = @()

# The target, unless the cluster's own Service answers it. The check is on the HOST, not
# on the URL: passing the whole URL here silently matched nothing, so `api-service` was
# pinned to one address - which for a multi-replica target would have measured a single
# pod while the run claimed to measure the deployment.
$targetHostName = ([System.Uri]$resolvedTarget).Host
if (-not (Test-IsClusterLocalName -HostName $targetHostName)) {
    $resolveHosts += $targetHostName
}

# The identity provider a scenario logs in against - from the Secret when it was
# credential-shaped, otherwise from the knobs.
$loginUrl = ''
if ($secretValues.Contains('LOGIN_URL')) {
    $loginUrl = "$($secretValues['LOGIN_URL'])"
}
else {
    $loginEntry = @($knobEntries | Where-Object { $_ -like 'LOGIN_URL=*' })
    if ($loginEntry.Count -gt 0) { $loginUrl = "$($loginEntry[0] -replace '^LOGIN_URL=', '')" }
}

if ($loginUrl) {
    try {
        $loginHost = ([System.Uri]$loginUrl).Host
        if (-not (Test-IsClusterLocalName -HostName $loginHost)) { $resolveHosts += $loginHost }
    }
    catch {
        Write-Warning "LOGIN_URL '$loginUrl' is not a URL this script can resolve a host from."
    }
}

$resolveHosts = @($resolveHosts | Select-Object -Unique)
if ($resolveHosts.Count -gt 0) { $runnerParameters['ResolveHost'] = @($resolveHosts) }
if ($writeUrl) { $runnerParameters['PrometheusWriteUrl'] = $writeUrl }
if (-not $SkipPreflight) { $runnerParameters['Preflight'] = $true }
if ($DeleteJobAfterRun) { $runnerParameters['DeleteJobAfterRun'] = $true }

Write-Host ''
Write-Host ('Cluster run: {0}' -f $resolvedTestType) -ForegroundColor Green
Write-Host ('  scenario    : k6/scripts/{0}  (from the {1} image)' -f $scenarioFile, $K6Image)
Write-Host  '  target      : ' -NoNewline; Write-Host $resolvedTarget
Write-Host ('  namespace   : {0}   replicas: {1}' -f $Namespace, $Replicas)

if ($SkipDeploy) {
    Write-Host '  API         : reused as it is (-SkipDeploy); meta.json records what was observed running'
}
elseif ($SkipBuild) {
    Write-Host ('  API image   : {0} (not built)' -f $resolvedImage)
}
else {
    Write-Host ('  API image   : {0}' -f $resolvedImage)
    Write-Host ('  build       : {0}' -f $resolvedDockerfile)
    Write-Host ('  context     : {0}' -f $resolvedBuildContext)
    if ($buildArguments.Count -gt 0) { Write-Host ('  build args  : {0}' -f ($buildArguments -join ', ')) }
    Write-Host ('  resources   : cpu {0}/{1}, memory {2}/{3} (request/limit)' -f $CpuRequest, $CpuLimit, $MemoryRequest, $MemoryLimit)
    if ($resolvedPublishDirectory) {
        Write-Host ('  publish dir : {0}' -f $resolvedPublishDirectory)
        # Worth saying out loud: the image copies the whole publish folder, and for this
        # application that folder is where its own .env (and so its Vault token) lives.
        if (Test-Path (Join-Path $resolvedPublishDirectory '.env') -PathType Leaf) {
            Write-Host '                (this folder contains a .env - it is copied into the image, as k8s/app/Dockerfile intends)' -ForegroundColor DarkGray
        }
    }
}

if ($secretValues.Count -gt 0) {
    Write-Host ('  secret      : {0} in {1} - keys: {2}' -f $CredentialsSecret, $Namespace, (($secretValues.Keys | Sort-Object) -join ', '))
    Write-Host  '                (values are never printed, and never written into results/)' -ForegroundColor DarkGray
}
if ($knobEntries.Count -gt 0) {
    Write-Host ('  knobs       : {0}' -f ($knobEntries -join ', '))
}
Write-Host ('  preflight   : {0}' -f $(if ($SkipPreflight) { 'skipped' } elseif ($resolvedTestType -eq 'smoke') { 'not needed - this IS the smoke test' } else { 'yes (1 VU smoke first)' }))
Write-Host ('  metrics     : {0}' -f $(if ($writeUrl) { "remote write to $writeUrl" } else { 'artefacts only' }))
Write-Host ''
Write-Host 'Equivalent without this script:' -ForegroundColor DarkGray
Write-Host ('  {0}' -f (Format-PlanArguments -Parameters $runnerParameters)) -ForegroundColor DarkGray
Write-Host ''

if ($DryRun) {
    Write-Host 'Dry run: nothing was built, deployed, or run.' -ForegroundColor Yellow
    exit 0
}

# ---------------------------------------------------------------------------
# 6. Observability, then the run.
# ---------------------------------------------------------------------------
if (-not $SkipObservability) {
    Write-Host 'Deploying the in-cluster Prometheus and Grafana...' -ForegroundColor Cyan
    & (Join-Path $PSScriptRoot 'deploy-observability.ps1')
    if ($LASTEXITCODE -ne 0 -and $null -ne $LASTEXITCODE) {
        throw "scripts/deploy-observability.ps1 failed with exit code $LASTEXITCODE."
    }
}

if ($secretValues.Count -gt 0) {
    # The namespace has to exist before a namespaced Secret can go into it, and on the
    # FIRST run of this wizard the deployment that would create it has not happened yet -
    # so it is created here, with the same name and label the runner's generated overlay
    # uses. Applying it twice is a no-op.
    $namespaceText = @(
        'apiVersion: v1'
        'kind: Namespace'
        'metadata:'
        "  name: $Namespace"
        '  labels:'
        '    app.kubernetes.io/part-of: perf-test-kit'
    )
    $namespaceText | & kubectl apply -f - 2>&1 | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
    if ($LASTEXITCODE -ne 0) {
        throw "Could not create namespace '$Namespace'. Is kubectl pointed at a cluster?"
    }

    # --dry-run=client then apply, so a second run updates the Secret instead of failing
    # with AlreadyExists and leaving the previous credentials in place.
    Write-Host ('Updating Secret {0} in {1}...' -f $CredentialsSecret, $Namespace) -ForegroundColor Cyan
    $secretText = New-CredentialsSecretText -Values $secretValues -Name $CredentialsSecret -NamespaceName $Namespace
    $secretText | & kubectl apply -f - 2>&1 | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
    if ($LASTEXITCODE -ne 0) {
        throw "Could not create Secret '$CredentialsSecret' in namespace '$Namespace'."
    }
}

Write-Host ''
& $runnerScript @runnerParameters
$exitCode = $LASTEXITCODE
if ($null -eq $exitCode) { $exitCode = 0 }

# ---------------------------------------------------------------------------
# 7. Where the evidence is.
# ---------------------------------------------------------------------------
$latestPath = Join-Path $repoRoot 'results\latest.txt'
$runDirectory = $null
if (Test-Path $latestPath -PathType Leaf) {
    $candidate = (Get-Content -Path $latestPath -Raw).Trim()
    if ($candidate -and (Test-Path $candidate -PathType Container)) { $runDirectory = $candidate }
}

if ($exitCode -eq 2) {
    Write-Host ''
    Write-Warning 'The preflight refused the run, so the real test never started. See preflight.log in the run directory.'
}

if ($runDirectory) {
    $summaryPath = Join-Path $runDirectory 'summary.json'
    $metaPath = Join-Path $runDirectory 'meta.json'
    $testId = Split-Path -Leaf $runDirectory

    Write-Host ''
    Write-Host 'Evidence:' -ForegroundColor Cyan
    Write-Host "  run     : $runDirectory"

    if ($writeUrl -and (Test-Path $summaryPath -PathType Leaf)) {
        # The window is read with Get-PerfTestSummaryWindow rather than from the parsed
        # JSON: ConvertFrom-Json turns those timestamps into [datetime] objects, and
        # re-formatting them loses the zone designator - which pointed a Grafana link
        # hours away from a run whose metrics were sitting in Prometheus all along.
        $window = Get-PerfTestSummaryWindow -Path $summaryPath
        if ($window) {
            $fromMs = $window.StartedAt.ToUnixTimeMilliseconds() - 10000
            $toMs = $window.EndedAt.ToUnixTimeMilliseconds() + 10000

            # Build the link for the port that answers. If none does, START one: a printed
            # link that needs a command run in another terminal is a link that does not
            # load, and there is no way for the reader to tell that apart from a broken
            # Grafana.
            $forward = $null
            if (Test-PerfTestTcpEndpoint -Port $grafanaNodePort) {
                $grafanaUrl = "http://127.0.0.1:$grafanaNodePort"
            }
            else {
                $forward = Start-GrafanaForward
                $grafanaUrl = if ($forward) { "http://127.0.0.1:$($forward.Port)" } else { $null }
            }

            if ($grafanaUrl) {
                $link = ('{0}/d/{1}?from={2}&to={3}&var-testid={4}&var_test_type={5}' -f `
                        $grafanaUrl, $dashboardUid, $fromMs, $toMs, $testId, $resolvedTestType)
                Write-Host ''
                Write-Host 'Grafana (this run, already zoomed to its window):' -ForegroundColor Cyan
                Write-Host "  $link"

                if ($forward -and $forward.Reused) {
                    Write-Host "  (through the port-forward already listening on 127.0.0.1:$($forward.Port))" -ForegroundColor DarkGray
                }
                elseif ($forward) {
                    Write-Host '  (a NodePort is not reachable on 127.0.0.1 on minikube or kind, so a SUPERVISED port-forward was' -ForegroundColor DarkGray
                    Write-Host "   started and left running: pid $($forward.ProcessId). It reconnects by itself if the pod behind the" -ForegroundColor DarkGray
                    Write-Host "   Service is replaced; stop it with Stop-Process -Id $($forward.ProcessId))" -ForegroundColor DarkGray
                }

                # A port-forward is attached to the pod behind the Service, and replacing that
                # pod kills it. The supervisor handles that; this is the manual fallback.
                Write-Host "  (if it stops loading anyway: pwsh -File scripts/expose-observability.ps1 -LocalPort $($forward.Port))" -ForegroundColor DarkGray

                Write-Host "  testid $testId" -ForegroundColor DarkGray
                Write-Host "  Check the data landed before trusting the dashboard: kubectl get --raw '/api/v1/namespaces/perf-observability/services/prometheus:9090/proxy/api/v1/query?query=sum(k6_http_reqs_total{testid=\"$testId\"})'" -ForegroundColor DarkGray
            }
            else {
                Write-Warning ('The dashboard could not be made reachable from this machine, so no link is printed rather ' +
                    'than one that will not load. A NodePort is opened on the node network, not on your loopback:')
                Write-Host "  kubectl port-forward -n perf-observability svc/grafana ${grafanaLocalPort}:3000" -ForegroundColor DarkGray
                Write-Host "  then open http://127.0.0.1:$grafanaLocalPort/d/$dashboardUid`?var-testid=$testId" -ForegroundColor DarkGray
                Write-Host '  or: minikube service -n perf-observability grafana' -ForegroundColor DarkGray
            }
        }
        else {
            Write-Warning "No usable time window in $summaryPath, so no Grafana link was built. Open $grafanaUrl/d/$dashboardUid and cover the run's period."
        }
    }

    if (Test-Path $metaPath -PathType Leaf) {
        Write-Host ''
        Write-Host '  Record the accepted numbers as this configuration''s baseline:' -ForegroundColor DarkGray
        Write-Host "    pwsh -File scripts/compare-summary.ps1 -Current `"$summaryPath`" -Baseline `"./baselines/$resolvedTestType.json`" -Update" -ForegroundColor DarkGray
    }
}

Write-Host ''
Write-Host ('The API is still deployed in {0}. Remove everything with: bash scripts/cleanup.sh {0}' -f $Namespace) -ForegroundColor DarkGray

if ($exitCode -eq 99) {
    Write-Host ''
    Write-Warning 'k6 exit code 99: one or more thresholds were crossed. For stress and spike, that is the finding.'
}

exit $exitCode
