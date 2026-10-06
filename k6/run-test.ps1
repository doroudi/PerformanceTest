<#
.SYNOPSIS
    Local authoring runner: k6 + Prometheus + Grafana in docker compose, against a
    target you name.

.DESCRIPTION
    Use this to write and debug scenarios, or to sanity-check that a script runs at
    all. Do NOT use it for capacity numbers: the generator and the system under test
    share one machine, the Docker network hop adds latency, and a laptop does not
    hold a steady clock or a steady thermal budget. Numbers from here are for
    "does it work", not for "how much can it take".

    For numbers that mean something, run the same scenarios against a staging or
    production-like environment with a dedicated load generator.

    Results still land in results/<timestamp>-<type>/ (summary.json + k6.log +
    meta.json), and the run feeds the Grafana dashboard via Prometheus remote-write.

.PARAMETER TargetUrl
    Required, and reachable FROM INSIDE a compose container - so not "localhost"
    or "127.0.0.1", which would be the k6 container itself. To reach something
    running on your machine use http://host.docker.internal:<port>.

    The target does NOT have to run in Docker. k6 runs in a container here; the
    API it tests can be any process on this machine - `dotnet run`, node, IIS
    Express, a Windows service. So for a service on port 5180:

        -TargetUrl http://host.docker.internal:5180/healthz

    Only the host name differs from what you would type in a browser.

    Whether a service bound only to 127.0.0.1 answers through that name depends on
    the host: Docker Desktop proxies to this machine's loopback, so it works as-is,
    while native Linux Docker routes to the bridge and the service must also bind
    0.0.0.0.

.PARAMETER TestType
    smoke | load | stress | soak | spike.

.PARAMETER EnvVars
    Scenario knobs in NAME=value form, e.g. -EnvVars TARGET_VUS=20,HOLD_DURATION=5m.

.EXAMPLE
    ./k6/run-test.ps1 -TargetUrl http://host.docker.internal:5000/api/health -TestType smoke

.EXAMPLE
    # An API started with `dotnet run` on this machine, bound to loopback only.
    ./k6/run-test.ps1 -TargetUrl http://host.docker.internal:5180/healthz -TestType load `
      -EnvVars TARGET_VUS=50,RAMP_DURATION=1m,HOLD_DURATION=5m
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateNotNullOrEmpty()]
    [string] $TargetUrl,

    [Parameter(Mandatory = $true, Position = 1)]
    [ValidateNotNullOrEmpty()]
    [string] $TestType,

    [string[]] $EnvVars = @(),
    [string] $ResultsRoot,

    # Path to a .env file of KEY=value lines. Omit it and the runner looks for k6\.env
    # and then <repo>\.env. Values from -EnvVars win over the file, so one run can
    # override a single knob without editing the file.
    [string] $EnvFile,

    # Path to a JSON file of test accounts, one per virtual user:
    #
    #   [{ "username": "a@example.com", "password": "..." }, ...]
    #
    # Omit it and the runner looks for k6\users.json. The pool is handed to k6 as
    # JOURNEY_USERS_JSON, which every scenario understands; with it, each VU authenticates
    # as its own account instead of the whole run sharing one.
    #
    # It is NOT passed through -EnvVars: that parser splits entries on commas, which would
    # quietly take a JSON array apart at the first one.
    [string] $UsersFile,

    # Escape hatch for the rare case where the target genuinely is inside the k6
    # container, or you are running with host networking.
    [switch] $AllowLocalhostTarget,

    # Skip the reachability preflight that normally runs before the longer profiles.
    [switch] $SkipPreflight,

    # Skip starting Prometheus/Grafana (they are already up, or you only want the log).
    [switch] $NoStack
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\scripts\lib\PerfTest.psm1') -Force

$repoRoot = Get-PerfTestRepoRoot
$scenariosDirectory = Join-Path $repoRoot 'k6\scripts'
$scenarioPath = Resolve-PerfTestScenario -TestType $TestType -ScenariosDirectory $scenariosDirectory
$scenarioFile = Split-Path -Leaf $scenarioPath
$composeFile = Join-Path $PSScriptRoot 'docker-compose.yml'
$resultsRoot = if ($ResultsRoot) { $ResultsRoot } else { Join-Path $repoRoot 'results' }

if ($TargetUrl -notmatch '^https?://') {
    throw "TargetUrl must start with http:// or https://, but got '$TargetUrl'."
}

# Reaching the target from inside a container is the most common way to get a load
# test that runs happily, reports progress, sends metrics - and measures nothing at
# all. So the checks below are errors, not warnings.
#
# The host is read through [System.Uri] rather than by regex because Uri normalises
# malformed-but-parseable literals: 'HTTP://127.0.01:5180/x' reports Host
# '127.0.0.1', which is how the typo below is caught. Go's resolver (what k6 uses) is
# stricter and treats '127.0.01' as a hostname, producing
# `lookup 127.0.01: no such host` - a DNS error for what looks like an IP address.
$targetHost = ''
try { $targetHost = ([System.Uri]$TargetUrl).Host.Trim('[', ']') } catch { }
if (-not $targetHost) {
    throw "TargetUrl '$TargetUrl' has no host that could be parsed."
}

$rawHostMatch = [regex]::Match($TargetUrl, '^[A-Za-z]+://(?<host>[^/:?#]+)')
$rawHost = if ($rawHostMatch.Success) { $rawHostMatch.Groups['host'].Value.Trim('[', ']') } else { '' }
$malformedHint = ''
if ($rawHost -match '^[0-9.]+$' -and $rawHost -ne $targetHost) {
    $malformedHint = (" Note also that '$rawHost' is not a valid IP literal - k6 reports it as " +
        "'lookup ${rawHost}: no such host' - and it parses as $targetHost.")
}

$loopbackReason = ''
if ($targetHost -ieq 'localhost' -or $targetHost -imatch '\.localhost$') {
    $loopbackReason = "'$targetHost' is the k6 container itself"
}
elseif ($targetHost -in @('0.0.0.0', '::', '::1')) {
    $loopbackReason = "'$targetHost' is not a routable address"
}
else {
    $parsedIp = $null
    if ([System.Net.IPAddress]::TryParse($targetHost, [ref]$parsedIp) -and [System.Net.IPAddress]::IsLoopback($parsedIp)) {
        $loopbackReason = "'$targetHost' is a loopback address, which inside the k6 container means the k6 container itself"
    }
}

function Get-HostTargetHint {
    <#
    Say whether a service bound to 127.0.0.1 on this machine is reachable as
    host.docker.internal from inside the container.

    Docker Desktop (Windows/macOS) proxies to the host's loopback, so a service that
    only listens on 127.0.0.1 still answers. Native Linux Docker routes the connection
    to the bridge instead, where a loopback-bound socket never sees it - there the
    service has to bind 0.0.0.0 as well.

    Best effort, and only evaluated on the failure path: if docker cannot be
    interrogated we state both cases rather than guess at one.
    #>
    $desktop = $null

    if (Get-Command docker -ErrorAction SilentlyContinue) {
        $previous = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $operatingSystem = (& docker info --format '{{.OperatingSystem}}' 2> $null | Out-String).Trim()
            if ($LASTEXITCODE -eq 0 -and $operatingSystem) {
                $desktop = $operatingSystem -match 'Docker Desktop'
            }
        }
        catch {
            $desktop = $null
        }
        finally {
            $ErrorActionPreference = $previous
        }
    }

    if ($desktop -eq $true) {
        return ("Docker Desktop is running the k6 container and it proxies to this machine's loopback, " +
            'so a service bound only to 127.0.0.1 is still reachable - no rebind needed for a local run.')
    }

    if ($desktop -eq $false) {
        return ('This is not Docker Desktop, so a service bound only to 127.0.0.1 is NOT reachable: ' +
            'it must also listen on 0.0.0.0 (for example ASPNETCORE_URLS=http://+:5180), and the container ' +
            'needs host.docker.internal mapped - docker-compose.yml does that via extra_hosts.')
    }

    return ("Whether a 127.0.0.1-bound service is reachable depends on the host: Docker Desktop reaches " +
        "this machine's loopback, native Linux Docker does not (bind 0.0.0.0 there as well).")
}

if ($loopbackReason) {
    # Show the exact URL to use instead, not a template. The reader has just
    # typed a command; making them do the <port><path> substitution themselves is
    # how this message gets read as "your setup is unsupported" instead of "one
    # word in your command is wrong".
    $suggestedUrl = [regex]::Replace(
        $TargetUrl,
        '^(?<scheme>[A-Za-z]+://)(?<host>[^/:?#]+)',
        '${scheme}host.docker.internal')

    $message = ("TargetUrl '$TargetUrl' cannot work from inside the k6 container: $loopbackReason, " +
        "not your machine.$malformedHint Every request fails in milliseconds and the test measures nothing - " +
        'and although the failures do appear in the metrics, there is nothing in the summary that names the cause.' +
        "`n  Use: $suggestedUrl" +
        "`n  Only the host name changes; the scheme, port and path stay exactly as they are." + "`n" +
        'Your API does NOT need to run in Docker. k6 runs in a container here, but the thing being tested can be ' +
        'any process on this machine - `dotnet run`, node, IIS Express, a Windows service. That is the normal case, ' +
        'and it is precisely what host.docker.internal exists for. ' +
        "$(Get-HostTargetHint) " +
        'Pass -AllowLocalhostTarget only if the target really is inside the k6 container itself.')
    if (-not $AllowLocalhostTarget) {
        throw $message
    }
    Write-Warning $message
}

# ---------------------------------------------------------------------------
# Configuration: a .env file first, then -EnvVars on top.
#
# The file is the convenient place for values that rarely change and must not be typed
# repeatedly - a login URL, an account, a password, an IdP client secret. -EnvVars wins
# so a single run can override one knob without editing the file, and so the documented
# examples keep working unchanged.
# ---------------------------------------------------------------------------
$envFileResult = Import-PerfTestEnvFile -ExplicitPath $EnvFile -SearchPaths @(
    (Join-Path $PSScriptRoot '.env')
    (Join-Path $repoRoot '.env')
)
$fileEnv = $envFileResult.Values
$commandLineEnv = ConvertTo-PerfTestEnvTable -EnvVars $EnvVars

if ($envFileResult.Path) {
    Write-Host "Environment file : $($envFileResult.Path)" -ForegroundColor Cyan
}
else {
    Write-Host "Environment file : none found (looked for k6\.env and .env). -EnvVars still applies." -ForegroundColor DarkGray
}

if ($fileEnv.ContainsKey('TARGET_URL')) {
    # Only worth saying when the two actually disagree. run-journey.ps1 resolves its
    # target FROM this file and then passes the same value as -TargetUrl, so warning
    # there would be noise about a value that is in fact being used.
    $fileTarget = "$($fileEnv['TARGET_URL'])"
    if ($fileTarget -ne $TargetUrl) {
        Write-Warning ("The environment file sets TARGET_URL='$fileTarget', which is ignored: the " +
            "target comes from -TargetUrl ('$TargetUrl') so that it is validated and recorded precisely " +
            'once. Remove it from the file, or pass the same value to -TargetUrl.')
    }
    $fileEnv.Remove('TARGET_URL')
}

$testEnv = @{}
foreach ($name in $fileEnv.Keys) { $testEnv[$name] = $fileEnv[$name] }
foreach ($name in $commandLineEnv.Keys) { $testEnv[$name] = $commandLineEnv[$name] }

# ---------------------------------------------------------------------------
# A pool of test accounts, one per virtual user.
#
# Added to the environment AFTER the merge above, so it cannot be mangled by the
# comma-splitting -EnvVars parser, and so a pool cannot be introduced through -EnvVars at
# all (which is also the path that would write it into an archived Job manifest on the
# cluster side).
# ---------------------------------------------------------------------------
$usersFilePath = Resolve-PerfTestUsersFile -ExplicitPath $UsersFile -Environment $fileEnv -SearchPaths @(
    (Join-Path $PSScriptRoot 'users.json')
)

if ($usersFilePath) {
    $usersJson = Read-PerfTestUsersFile -Path $usersFilePath
    $testEnv['JOURNEY_USERS_JSON'] = $usersJson

    $parsedUsers = $usersJson | ConvertFrom-Json
    $accounts = if ($parsedUsers -is [array]) { @($parsedUsers) } elseif ($parsedUsers.users) { @($parsedUsers.users) } else { @() }

    Write-Host "Accounts      : $($accounts.Count) from $usersFilePath" -ForegroundColor Cyan
    Write-Host '                (each VU authenticates as one of them; tags carry user-01, user-02, ...)' -ForegroundColor DarkGray
}

# docker compose v2 (plugin) vs the standalone v1 binary.
$composeExecutable = 'docker'
$composePrefix = @('compose')
$previous = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    & docker compose version *> $null
    $composeAvailable = ($LASTEXITCODE -eq 0)
}
finally {
    $ErrorActionPreference = $previous
}
if (-not $composeAvailable) {
    if (Get-Command docker-compose -ErrorAction SilentlyContinue) {
        $composeExecutable = 'docker-compose'
        $composePrefix = @()
    }
    else {
        throw 'Neither "docker compose" (v2) nor "docker-compose" (v1) is available.'
    }
}

# Global compose options, used by every invocation.
# `--profile k6` because the k6 service sits behind a profile: naming the profile
# keeps `up` and `run` working whether or not it is enabled in the environment.
$composeGlobal = $composePrefix + @('-f', $composeFile, '--profile', 'k6')

function Invoke-Compose {
    param([Parameter(Mandatory = $true)][string[]] $Arguments)

    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $composeExecutable @($composeGlobal + $Arguments)
        return $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previous
    }
}

# 127.0.0.1 and never `localhost`. Docker Desktop also publishes these ports on
# IPv6, and its IPv6 proxy does not answer on at least this machine, so a
# `localhost` URL hangs until something times out instead of failing fast. Both
# were measured: http://127.0.0.1:9090 answered immediately while
# http://[::1]:9090 and http://localhost:9090 timed out. A browser eventually
# falls back to IPv4 and appears to work, which is why this was never obvious.
$grafanaUrl = 'http://127.0.0.1:3000'
$prometheusUrl = 'http://127.0.0.1:9090'
$dashboardUid = 'k6-load-test'

if (-not $NoStack) {
    Write-Host 'Starting Prometheus, Grafana and the demo target...' -ForegroundColor Cyan
    $stackExit = Invoke-Compose -Arguments @('up', '-d', 'prometheus', 'grafana', 'demo-target')
    if ($stackExit -ne 0) {
        throw "'$composeExecutable $($composePrefix -join ' ') up -d prometheus grafana demo-target' failed with exit code $stackExit."
    }
    Write-Host "Grafana:    $grafanaUrl/d/$dashboardUid  (this run's results)" -ForegroundColor Cyan
    Write-Host "Prometheus: $prometheusUrl/graph  (raw k6 metrics)" -ForegroundColor Cyan
}

$runDirectory = New-PerfTestRunDirectory -ResultsRoot $resultsRoot -Name $TestType
$logPath = Join-Path $runDirectory 'k6.log'
$summaryPath = Join-Path $runDirectory 'summary.json'
$metaPath = Join-Path $runDirectory 'meta.json'

# Unique id so Grafana / PromQL can filter this run
$testId = '{0}-{1}' -f (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss'), $TestType

$runArguments = @('run', '--rm')
$runArguments += @('-e', "TARGET_URL=$TargetUrl")
foreach ($name in ($testEnv.Keys | Sort-Object)) {
    $runArguments += @('-e', "$name=$($testEnv[$name])")
}
# The Prometheus output is deliberately NOT enabled here. It is set once, as
# K6_OUT in docker-compose.yml, so that a plain
# `docker compose run --rm k6 run /scripts/smoke-test.js` also sends metrics
# instead of silently writing nothing. Passing --out here as well would register a
# second output and push every sample twice.
#
# `--tag testid=` labels this run's series so Grafana panels and PromQL can be
# filtered to one run.
#
# `--tag test_type=` is passed HERE, from the runner, and not left to the
# scenarios' own `options.tags`. Measured on a real run: the tag set inside
# `options.tags` in a scenario file does NOT reach Prometheus at all - the
# k6_* series carried testid but no test_type label - while the same tag passed
# as a CLI --tag arrived as test_type="probe". Without this line the dashboard's
# test-type filter silently matches nothing.
$runArguments += @(
    'k6',
    'run',
    '--tag', "testid=$testId",
    '--tag', "test_type=$TestType",
    "/scripts/$scenarioFile"
)

# A first local `load` run takes 12 minutes with the scenario defaults (1m ramp +
# 10m hold + 1m ramp-down), which is easy to interrupt by mistake and lose the
# summary. Say so, and say how to shorten it.
$shortenHints = @{
    load   = 'RAMP_DURATION=10s,HOLD_DURATION=30s'
    soak   = 'RAMP_DURATION=10s,HOLD_DURATION=60s'
    stress = 'STEP_DURATION=15s,STRESS_STEPS=2,STEP_VUS=5'
    spike  = 'BASELINE_DURATION=10s,SPIKE_DURATION=20s,SPIKE_VUS=50'
}
if ($shortenHints.ContainsKey($TestType)) {
    Write-Host ("Note: '{0}' with scenario defaults runs far longer than a smoke test." -f $TestType) -ForegroundColor DarkGray
    Write-Host ("      For a quick local check:  -EnvVars {0}" -f $shortenHints[$TestType]) -ForegroundColor DarkGray
    Write-Host '      Longer profiles belong on a prod-shaped environment, not a laptop.' -ForegroundColor DarkGray
    Write-Host ''
}

# ---------------------------------------------------------------------------
# Preflight: make the target prove it answers, before spending the profile's
# duration on it. A 12-minute load test that is 100% connection failures is the
# most expensive possible way to learn that a hostname is wrong.
# ---------------------------------------------------------------------------
if (-not $SkipPreflight -and $TestType -ne 'smoke') {
    $preflightLog = Join-Path $runDirectory 'preflight.log'
    $preflightArgs = @('run', '--rm')
    $preflightArgs += @('-e', "TARGET_URL=$TargetUrl")
    $preflightArgs += @('-e', 'TARGET_VUS=1', '-e', 'TEST_DURATION=4s', '-e', 'REQUEST_PAUSE=0')
    $preflightArgs += @('k6', 'run', '--tag', "testid=$testId-preflight", '--tag', 'test_type=preflight', '/scripts/smoke-test.js')

    Write-Host 'Preflight: checking the target answers from inside the container...' -ForegroundColor Cyan
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $composeExecutable @($composeGlobal + $preflightArgs) 2>&1 |
            Tee-Object -FilePath $preflightLog | Out-Null
    }
    finally {
        $ErrorActionPreference = $previous
    }

    $preflightText = if (Test-Path $preflightLog -PathType Leaf) { Get-Content -Path $preflightLog -Raw } else { '' }
    $preflightSummary = $null
    try {
        $preflightSummary = Get-K6SummaryFromText -Text $preflightText
    }
    catch {
        $preflightSummary = $null
    }

    $failureRate = $null
    if ($preflightSummary -and $preflightSummary.metrics -and $preflightSummary.metrics.http_req_failed) {
        $failureRate = [double]$preflightSummary.metrics.http_req_failed.rate
    }

    if ($null -eq $failureRate -or $failureRate -ge 1) {
        # k6's own error line names the real cause: "no such host", "connection
        # refused", or a 404 from the wrong path.
        $cause = @(($preflightText -split "`r?`n") | Where-Object {
                $_ -match 'level=(error|warning)|Request Failed|Error response|error during connect|Cannot connect to the Docker daemon|error='
            } | Select-Object -First 3)

        Write-Host ''
        Write-Warning "Not one request succeeded, so the $TestType test would measure nothing but failures."
        $cause | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
        Write-Host "  Preflight log: $preflightLog"
        Write-Host 'Check, in order:'
        Write-Host '  1. the host must be reachable from a container - use host.docker.internal, never localhost or 127.x'
        Write-Host '  2. the app must listen on all interfaces: `dotnet run` binds 127.0.0.1 only'
        Write-Host '  3. the path must exist - a 404 counts as a failed request here'
        Write-Host '  4. the port must be reachable from the compose network'
        Write-Host 'Re-run with -SkipPreflight to ignore this and run anyway.'
        exit 2
    }

    Write-Host ('Preflight OK: {0:P0} of requests failed.' -f $failureRate) -ForegroundColor Green
    Write-Host ''
}

Write-Host "Running the $TestType test against $TargetUrl (testid=$testId) ..." -ForegroundColor Cyan

# stderr is left alone on purpose: docker compose and k6 write progress and errors
# there, while k6's summary goes to stdout, which is what gets captured for parsing.
$exitCode = 0
$previous = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    # 2>&1 on purpose: k6 writes its end-of-test summary to stdout, but every
    # level=error line - including remote-write push failures, which is exactly
    # what you need when Grafana is empty - goes to stderr. Capturing stdout alone
    # leaves the diagnostics out of the artefact.
    #
    # Safe here because ErrorActionPreference is Continue in this block: with
    # 'Stop', merging a native command's stderr can throw a NativeCommandError
    # before the exit code can be read.
    & $composeExecutable @($composeGlobal + $runArguments) 2>&1 |
        Tee-Object -FilePath $logPath |
        Out-Host
    $exitCode = $LASTEXITCODE
}
finally {
    $ErrorActionPreference = $previous
}

$logText = if (Test-Path $logPath -PathType Leaf) { Get-Content -Path $logPath -Raw } else { '' }
$rawJson = Get-K6SummaryJsonFromText -Text $logText
Write-Utf8NoBom -Path $summaryPath -Content $rawJson | Out-Null
$summary = $rawJson | ConvertFrom-Json

$markers = Get-PerfTestSummaryMarkers
$humanEnd = $logText.IndexOf($markers.Begin)
if ($humanEnd -gt 0) {
    Write-Host $logText.Substring(0, $humanEnd).TrimEnd()
}

$revision = Get-PerfTestGitRevision

Write-PerfTestMetadata -Path $metaPath -Data @{
    schema            = 'perftest.run/v1'
    runner            = 'k6/run-test.ps1 (docker compose / prometheus)'
    test_type         = $TestType
    testid            = $testId
    target_url        = $TargetUrl
    scenario          = $scenarioFile
    # Masked on purpose. meta.json is an artefact people attach to tickets and paste
    # into chat, so a JOURNEY_PASSWORD or AUTH_CLIENT_SECRET must not be in it. The KEY
    # is kept, because "a password was supplied" is part of reproducing a run; only the
    # value is replaced.
    env_vars          = (Protect-PerfTestSecretValues -Environment $testEnv)
    git_revision      = $revision
    k6_exit_code      = $exitCode
    thresholds_all_ok = $summary.thresholds_all_ok
    failed_thresholds = @($summary.failed_thresholds)
    finished_at       = (Get-Date).ToUniversalTime().ToString('o')
} | Out-Null

Write-Host ''
Write-Host 'Run artefacts:' -ForegroundColor Cyan
Write-Host "  run      : $runDirectory"
Write-Host "  log      : $logPath"
Write-Host "  summary  : $summaryPath"
Write-Host "  metadata : $metaPath"
Write-Host "  testid   : $testId  (filter Grafana panels with this)"

# A link that opens Grafana on THIS run.
#
# This is the fix for the single most common complaint about this kit - "Grafana
# shows no data". The metrics were always delivered; the dashboard's own time
# range simply no longer covered a run that had finished. k6 writes samples only
# while the test is running, so once the run stops, an instant query at "now"
# returns nothing and every panel reads "No data". Measured on the real stack:
# the dashboard's own queries returned 56 metric names and 0.83 req/s when
# evaluated at the run's timestamp, and zero series when evaluated at "now".
#
# Pinning from/to to the measured window (+/- 10s of slack for the first and
# last push) removes that failure mode entirely. The var-testid and var-test_type
# parameters pre-select the template variables, so the link shows exactly one run.
# NOTE: the window is read with Get-PerfTestSummaryWindow, NOT from
# $summary.started_at. ConvertFrom-Json has already turned those fields into
# [datetime] objects, and re-parsing them loses the zone designator and makes
# them LOCAL time - measured at exactly this machine's UTC offset (+03:30), which
# pointed the dashboard 3.5 hours before a run whose metrics were sitting in
# Prometheus the whole time. The helper regexes the raw ISO strings instead.
$window = Get-PerfTestSummaryWindow -Path $summaryPath
if ($window) {
    $fromMs = $window.StartedAt.ToUnixTimeMilliseconds() - 10000
    $toMs = $window.EndedAt.ToUnixTimeMilliseconds() + 10000
    $grafanaLink = ('{0}/d/{1}?from={2}&to={3}&var-testid={4}&var-test_type={5}' -f `
            $grafanaUrl, $dashboardUid, $fromMs, $toMs, $testId, $TestType)
    Write-Host ''
    Write-Host 'Grafana (this run, already zoomed to its window):' -ForegroundColor Cyan
    Write-Host "  $grafanaLink"
}
else {
    Write-Warning ("No usable time window in $summaryPath, so no Grafana link was built. " +
        "Open $grafanaUrl/d/$dashboardUid and set the range to cover this run.")
}

if ($exitCode -eq 99) {
    Write-Host ''
    Write-Warning 'k6 exit code 99: one or more thresholds were crossed.'
}
elseif ($exitCode -ne 0) {
    Write-Host ''
    Write-Warning "k6 exited with code $exitCode."
}

Write-Host ''
Write-Host 'Reminder: local numbers are for script validity, not capacity.' -ForegroundColor DarkGray
Write-Host 'Run the same scenarios against staging or a production-like environment for real measurements.' -ForegroundColor DarkGray

exit $exitCode