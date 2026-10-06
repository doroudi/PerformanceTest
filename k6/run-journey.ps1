<#
.SYNOPSIS
    Run the multi-step journey scenario, the one that logs in first.

.DESCRIPTION
    A thin, purpose-built front end for k6/run-test.ps1 -TestType journey. It exists
    because the journey has requirements the generic runner cannot infer:

      1. It needs a login URL and an account. Those come from a .env file or from the
         operator, never from a default baked into a scenario file.
      2. It must NOT run the reachability preflight. The preflight sends an
         unauthenticated request to the target; an API behind a token answers 401, so
         the preflight declares the target dead and stops the run with exit code 2
         before the journey ever starts. This script always passes -SkipPreflight.
      3. The password must not be echoed, put in shell history, or archived.

    Everything else - the run directory, summary.json, meta.json, the testid, the
    Grafana link - belongs to run-test.ps1 and is reused unchanged, so a journey run and
    a smoke run produce comparable artifacts in the same place.

CONFIGURATION, AND WHERE IT COMES FROM
    Values are resolved in this order, first hit winning:

      1. the command line
      2. the .env file (see below)
      3. for the account and the password only: an interactive prompt
      4. otherwise a clear error naming what is missing

    A .env file is looked up at k6\.env, then <repo>\.env, unless -EnvFile names one.
    Copy .env.example to k6\.env to start. k6\.env is gitignored; keep it that way,
    because it holds a password.

.PARAMETER TargetUrl
    The API base, e.g. https://example.com. Becomes TARGET_URL, which
    the journey uses as the base for its steps. May come from TARGET_URL or API_BASE_URL
    in the .env file.

.PARAMETER LoginUrl
    The JSON login endpoint that returns data.accessToken. May come from LOGIN_URL in
    the .env file.

.PARAMETER Username
    The account to log in as. May come from JOURNEY_USERNAME. If neither is set, you are
    prompted.

.PARAMETER Password
    A SecureString. Prefer leaving it unset: put JOURNEY_PASSWORD in .env, or let the
    script prompt with hidden input. A password passed as a plain argument is captured
    by shell history and by any process listing.

.PARAMETER EnvFile
    Path to the .env file. Omit to use the default search.

.PARAMETER UsersFile
    Path to a JSON file of test accounts, one per virtual user:

      [{ "username": "a@example.com", "password": "..." }, ...]

    Omit it and k6\users.json is used when it exists, so the usual setup is one file and one
    command. With a pool, each VU runs the journey as its OWN account and each request is
    tagged with user-01, user-02, ... - see the note in journey-test.js about why thirty VUs
    sharing one account is a different (and misleading) test.

    Pass -Vus equal to the number of accounts to give every VU a distinct one.

.PARAMETER Vus
    Concurrent virtual users for the default steady profile. Default 5, or TARGET_VUS from
    the file. Ignored by -Profile stress and -Profile spike, which compute their own VU
    counts from STEP_VUS/STRESS_STEPS and BASELINE_VUS/SPIKE_VUS.

.PARAMETER Profile
    steady (default) | load | stress | spike - the load SHAPE, not the test type.

      steady   Vus for Duration, constant (what the journey has always done)
      load     ramp to Vus, hold, ramp down        RAMP_DURATION, HOLD_DURATION
      stress   plateaus, each STEP_VUS larger      STEP_VUS, STRESS_STEPS, STEP_DURATION
      spike    baseline, spike, back to baseline   BASELINE_VUS, SPIKE_VUS, ...

    For a stress run the per-step thresholds are EXPECTED to fail: that is the finding, not a
    broken build. The failure gate is loosened for those profiles and will not abort the run.

.PARAMETER EnvVars
    Extra scenario knobs, NAME=value, comma separated - e.g
    -EnvVars STEP_VUS=10,STRESS_STEPS=4,STEP_DURATION=2m. These win over the environment file.

.PARAMETER Duration
    How long the VUs keep repeating the journey. Default 1m, or TEST_DURATION.

.PARAMETER StepPause
    Think time in seconds BETWEEN the three steps. Default 0, or STEP_PAUSE.

.PARAMETER RequestPause
    Think time in seconds between one journey and the next. Default 0.5, or REQUEST_PAUSE.

.PARAMETER ApiBaseUrl
    Only needed when the recorded target and the API base must differ.

.PARAMETER AllowProduction
    The journey logs in and exercises real endpoints, so a production-looking host is
    refused unless this switch is present. A heuristic, deliberately easy to override:
    it is there to catch a copy-pasted command.

.EXAMPLE
    # Everything from k6\.env except the password, which is prompted for.
    pwsh -File k6/run-journey.ps1

.EXAMPLE
    # Override the load for one run; everything else still comes from the file.
    pwsh -File k6/run-journey.ps1 -Vus 1 -Duration 10s

.EXAMPLE
    # Nothing from a file: credentials on the command line.
    pwsh -File k6/run-journey.ps1 `
      -TargetUrl https://example.com `
      -LoginUrl  https://example.com.dev/accounts/login `
      -Username  someone@example.com
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string] $TargetUrl,
    [Parameter(Position = 1)][string] $LoginUrl,
    [Parameter(Position = 2)][string] $Username,

    [System.Security.SecureString] $Password,

    [ValidateRange(1, 2000)][int] $Vus = 5,
    [string] $Duration = '1m',
    [ValidateSet('steady', 'load', 'stress', 'spike', 'rate', 'rate-ramp')][string] $Profile = 'steady',
    [string[]] $EnvVars = @(),
    [ValidateRange(0, 600)][double] $StepPause = 0,
    [ValidateRange(0, 600)][double] $RequestPause = 0.5,

    [string] $ApiBaseUrl,
    [string] $EnvFile,
    [string] $UsersFile,
    [string] $ResultsRoot,

    [switch] $NoStack,
    [switch] $AllowProduction
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\scripts\lib\PerfTest.psm1') -Force

$repoRoot = Get-PerfTestRepoRoot

# ---------------------------------------------------------------------------
# 1. The .env file.
#
# Loaded first so every value below can fall back to it. -EnvFile naming a file that
# does not exist is an error rather than a silent fallback to another file: "I pointed
# at my file and it used a different one" is exactly the confusing outcome this is meant
# to remove.
# ---------------------------------------------------------------------------
$envFileResult = Import-PerfTestEnvFile -ExplicitPath $EnvFile -SearchPaths @(
    (Join-Path $PSScriptRoot '.env')
    (Join-Path $repoRoot '.env')
)
$fileEnv = $envFileResult.Values

# A pool of accounts, one per VU, replaces the single account entirely: no username to
# resolve, no password to prompt for, nothing to redact. Resolved before the account
# handling below so that "is an account needed at all?" is answered once.
$usersFilePath = Resolve-PerfTestUsersFile -ExplicitPath $UsersFile -Environment $fileEnv -SearchPaths @(
    (Join-Path $PSScriptRoot 'users.json')
)
$pooled = -not [string]::IsNullOrEmpty($usersFilePath)

if ($envFileResult.Path) {
    Write-Host "Environment file : $($envFileResult.Path)" -ForegroundColor Cyan
}
else {
    Write-Host 'Environment file : none found (looked for k6\.env and .env)' -ForegroundColor DarkYellow
}

# Which knobs did the operator actually pass?
#
# $PSBoundParameters inside a helper function refers to the HELPER's parameters, not the
# script's, so asking the helper "was -Duration provided?" silently answers "no" and the
# file (or the parameter default) wins over the command line. That is invisible in
# testing, because a value still gets used - just not the one that was asked for. The
# answer therefore has to be read here, at script scope, and handed in.
$cliBound = $PSBoundParameters

# First hit wins: command line, then file, then the supplied default.
function Get-Setting {
    param([string] $CommandLineValue, [string] $Name, [string] $Default = '')

    if (-not [string]::IsNullOrWhiteSpace($CommandLineValue)) { return $CommandLineValue }
    if ($fileEnv.ContainsKey($Name) -and -not [string]::IsNullOrWhiteSpace("$($fileEnv[$Name])")) {
        return "$($fileEnv[$Name])"
    }
    return $Default
}

# For parameters that carry a default of their own, "is it empty?" cannot distinguish
# "not passed" from "passed the same value as the default", so WasProvided decides.
function Get-TypedSetting {
    param([bool] $WasProvided, $ProvidedValue, [string] $Name, $Default)

    if ($WasProvided) { return $ProvidedValue }
    if ($fileEnv.ContainsKey($Name) -and -not [string]::IsNullOrWhiteSpace("$($fileEnv[$Name])")) {
        return "$($fileEnv[$Name])"
    }
    return $Default
}

$resolvedTarget = Get-Setting $TargetUrl 'TARGET_URL'
if (-not $resolvedTarget) { $resolvedTarget = Get-Setting $TargetUrl 'API_BASE_URL' }
$resolvedLogin = Get-Setting $LoginUrl 'LOGIN_URL'
$resolvedUsername = Get-Setting $Username 'JOURNEY_USERNAME'
$resolvedApiBase = Get-Setting $ApiBaseUrl 'API_BASE_URL'

try {
    $resolvedVus = [int](Get-TypedSetting $cliBound.ContainsKey('Vus') $Vus 'TARGET_VUS' 7)
    $resolvedDuration = [string](Get-TypedSetting $cliBound.ContainsKey('Duration') $Duration 'TEST_DURATION' '1m')
    $resolvedProfile = [string](Get-TypedSetting $cliBound.ContainsKey('Profile') $Profile 'JOURNEY_PROFILE' 'steady')
    $resolvedStepPause = [double](Get-TypedSetting $cliBound.ContainsKey('StepPause') $StepPause 'STEP_PAUSE' 0)
    $resolvedRequestPause = [double](Get-TypedSetting $cliBound.ContainsKey('RequestPause') $RequestPause 'REQUEST_PAUSE' 0.5)
}
catch {
    throw ("A load-profile value in the environment file is not usable: $($_.Exception.Message)`n" +
        'TARGET_VUS, STEP_PAUSE and REQUEST_PAUSE must be numbers; TEST_DURATION is a duration such as 30s or 1m.')
}

if (@('steady', 'load', 'stress', 'spike', 'rate', 'rate-ramp') -notcontains $resolvedProfile) {
    throw ("JOURNEY_PROFILE is '$resolvedProfile', which is not one of: steady, load, stress, spike.`n" +
        'Fix it in the environment file, or pass -Profile on the command line.')
}

# What each shape means, said in the run's own output rather than only in a doc: a stress run
# whose thresholds fail is the expected outcome, and that is worth stating before it happens.
$profileDescription = @{
    steady    = "$resolvedVus VU(s) for $resolvedDuration, constant (closed model - offered load falls when the target slows)"
    load      = "ramp to $resolvedVus VU(s), hold, ramp down (RAMP_DURATION / HOLD_DURATION)"
    stress    = "stepped plateaus of STEP_VUS, STRESS_STEPS times, then a plateau at 0 (STEP_DURATION)"
    spike     = "baseline, spike to SPIKE_VUS, back to baseline (recovery window)"
    rate      = "a FIXED TARGET_RPS for TEST_DURATION (open model - the offered load does not fall when the target slows)"
    'rate-ramp' = "a FIXED offered rate rising in RATE_STEPS steps, then back to 0 (open model)"
}

# ---------------------------------------------------------------------------
# 2. Anything still missing.
#
# URLs are an error rather than a prompt: a mistyped URL wastes a whole run and fails
# somewhere confusing, while a mistyped account fails immediately and obviously. So the
# account and the password are prompted for, and the URLs are not.
# ---------------------------------------------------------------------------
$missingUrls = @()
if (-not $resolvedTarget) { $missingUrls += 'TARGET_URL (or API_BASE_URL)' }
if (-not $resolvedLogin) { $missingUrls += 'LOGIN_URL' }

if ($missingUrls.Count -gt 0) {
    throw ('Missing required configuration: ' + ($missingUrls -join ', ') + ".`n" +
        'Provide them on the command line, or put them in k6\.env, for example:' + "`n`n" +
        "  TARGET_URL=https://example.com`n" +
        "  LOGIN_URL=https://example.com.dev/accounts/login`n" +
        "  JOURNEY_USERNAME=someone@example.com`n" +
        "  JOURNEY_PASSWORD=...`n")
}

foreach ($url in @($resolvedTarget, $resolvedLogin)) {
    if ($url -notmatch '^https?://') {
        throw "URLs must start with http:// or https://, but got '$url'."
    }
}

if (-not $resolvedUsername -and -not $pooled) {
    Write-Host 'Username was not supplied and is not in the environment file.' -ForegroundColor Cyan
    $resolvedUsername = (Read-Host 'Account username').Trim()
    if (-not $resolvedUsername) { throw 'No username was supplied.' }
}

# ---------------------------------------------------------------------------
# 3. Refuse a production-looking host unless it was meant.
#
# This test logs in as a real person and then exercises real endpoints. Against
# production it would both distort that environment and be indistinguishable from real
# user traffic - the last thing anyone wants from a load test.
# ---------------------------------------------------------------------------
$targetHost = ([System.Uri]$resolvedTarget).Host
if (-not $AllowProduction -and $targetHost -match '(?i)(^|[.\-])prod(uction)?([.\-]|$)') {
    throw ("Refusing to run against '$targetHost': the host name looks like production, and this " +
        'test logs in as a real user and exercises real endpoints. Pass -AllowProduction if that ' +
        'is genuinely intended.')
}

# ---------------------------------------------------------------------------
# 4. The password. Never printed, whatever its source.
# ---------------------------------------------------------------------------
if ($pooled) {
    # The pool carries the credentials, so there is nothing to prompt for and nothing that
    # could end up in an artefact: the file is handed to k6 as a variable, and the runners
    # on the cluster side put it in a Secret.
    $plainPassword = ''
    $passwordSource = "the credential pool ($usersFilePath)"
}
elseif ($null -ne $Password) {
    if ($Password.Length -eq 0) { throw 'The password is empty.' }
    $plainPassword = [System.Net.NetworkCredential]::new('', $Password).Password
    $passwordSource = 'command line'
}
elseif ($fileEnv.ContainsKey('JOURNEY_PASSWORD') -and -not [string]::IsNullOrWhiteSpace("$($fileEnv['JOURNEY_PASSWORD'])")) {
    $plainPassword = "$($fileEnv['JOURNEY_PASSWORD'])"
    $passwordSource = 'environment file'
}
else {
    Write-Host "Password for $resolvedUsername (input is hidden):" -ForegroundColor Cyan
    $secure = Read-Host -AsSecureString
    if ($secure.Length -eq 0) { throw 'The password is empty.' }
    $plainPassword = [System.Net.NetworkCredential]::new('', $secure).Password
    $passwordSource = 'prompt'
}

# ---------------------------------------------------------------------------
# 5. -EnvVars is a comma-separated list and the parser splits on commas, so a comma
# inside a value cannot be represented. Failing here with an explanation beats a login
# that mysteriously rejects good credentials, because the value would be silently
# truncated at the comma and a different password sent.
# ---------------------------------------------------------------------------
foreach ($pair in @(
        @('Username', $resolvedUsername),
        @('Password', $plainPassword),
        @('TargetUrl', $resolvedTarget),
        @('LoginUrl', $resolvedLogin))) {
    if ($pair[1] -like '*,*') {
        throw ("The $($pair[0]) contains a comma. The runner passes environment variables as a " +
            'comma-separated list, so a value containing a comma cannot be expressed. Use a value ' +
            'without one, or unset -EnvVars and drive k6 directly.')
    }
}

$envEntries = @(
    # The journey authenticates itself: one login in setup(), reused by every VU - or one per
    # VU when a credential pool is in use. The generic mechanism in lib/auth.js would log in
    # again on top of that, so it is switched off for this run. Without this, a .env file
    # that enables json-login for the other test types would also apply here and cost a
    # redundant login for every VU.
    'AUTH_MODE=off'
    "LOGIN_URL=$resolvedLogin"
    "TARGET_VUS=$resolvedVus"
    "TEST_DURATION=$resolvedDuration"
    "JOURNEY_PROFILE=$resolvedProfile"
    "STEP_PAUSE=$resolvedStepPause"
    "REQUEST_PAUSE=$resolvedRequestPause"
)

# Knobs the profile needs (STEP_VUS, STRESS_STEPS, STEP_DURATION, HOLD_DURATION, ...) reach
# k6 the same way - from the environment file, or from here. They are not enumerated: the
# scenario owns their names and defaults, and a second list here would drift from it.
foreach ($entry in $EnvVars) {
    foreach ($part in ("$entry" -split ',')) {
        if ($part.Trim()) { $envEntries += $part.Trim() }
    }
}

# The single account is passed only when there IS one: with a pool, setting
# JOURNEY_USERNAME as well would be two sources of truth for the same thing, and the
# scenario would have to tell you which won.
if (-not $pooled) {
    $envEntries += "JOURNEY_USERNAME=$resolvedUsername"
    $envEntries += "JOURNEY_PASSWORD=$plainPassword"
}

if ($resolvedApiBase) { $envEntries += "API_BASE_URL=$resolvedApiBase" }

Write-Host ''
Write-Host 'Journey load test' -ForegroundColor Cyan
Write-Host "  API base   : $resolvedTarget"
Write-Host "  login      : $resolvedLogin"
if ($pooled) {
    $poolJson = Read-PerfTestUsersFile -Path $usersFilePath
    $poolParsed = $poolJson | ConvertFrom-Json
    $poolAccounts = if ($poolParsed -is [array]) { @($poolParsed) } elseif ($poolParsed.users) { @($poolParsed.users) } else { @() }

    Write-Host "  accounts   : $($poolAccounts.Count) from $usersFilePath  (one per VU, round robin)"
    if ($poolAccounts.Count -lt $resolvedVus) {
        Write-Host ("               fewer accounts than VUs, so $($poolAccounts.Count) account(s) will be shared -" ) -ForegroundColor DarkYellow
        Write-Host '               raise the pool size or lower -Vus for one account per VU.' -ForegroundColor DarkYellow
    }
    elseif ($poolAccounts.Count -gt $resolvedVus) {
        Write-Host "               $($poolAccounts.Count - $resolvedVus) account(s) will go unused at -Vus $resolvedVus." -ForegroundColor DarkYellow
    }
}
else {
    Write-Host "  account    : $resolvedUsername  (password from $passwordSource, not echoed)"
}
Write-Host "  load       : $($profileDescription[$resolvedProfile])"
Write-Host "  think time : $resolvedStepPause s between steps, $resolvedRequestPause s between journeys"
Write-Host '  steps      : kyc-step -> wallets -> requests-active, each measured separately'
Write-Host ''
Write-Host 'The preflight is skipped on purpose: it would test the API unauthenticated, get a 401,' -ForegroundColor DarkGray
Write-Host 'and stop the run before the journey started.' -ForegroundColor DarkGray
Write-Host ''

# ---------------------------------------------------------------------------
# 6. Hand off to the generic runner.
#
# -SkipPreflight is not negotiable here (see above). -EnvFile is passed through as well,
# so any other key in the file (REQUEST_HEADERS, AUTH_*) reaches k6 too; the explicit
# -EnvVars above win over it for the keys this script resolved.
#
# -UsersFile is passed as its own parameter, not as an env entry: a JSON array contains
# commas, and the -EnvVars parser splits on commas.
# ---------------------------------------------------------------------------
$runnerArguments = @{
    TargetUrl     = $resolvedTarget
    TestType      = 'journey'
    EnvVars       = $envEntries
    SkipPreflight = $true
}

if ($pooled) { $runnerArguments.UsersFile = $usersFilePath }
if ($envFileResult.Path) { $runnerArguments.EnvFile = $envFileResult.Path }
if ($ResultsRoot) { $runnerArguments.ResultsRoot = $ResultsRoot }
if ($NoStack) { $runnerArguments.NoStack = $true }

$plainPassword = $null

& (Join-Path $PSScriptRoot 'run-test.ps1') @runnerArguments
exit $LASTEXITCODE
