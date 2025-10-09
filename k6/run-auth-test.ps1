<#
.SYNOPSIS
    Run any single-endpoint test type against an AUTHENTICATED target.

.DESCRIPTION
    A front end for k6/run-test.ps1 for the case where the system under test needs a
    token. It exists for one reason, and it is not convenience:

        A protected endpoint answers 401 to every request. k6 records that as a FAST run
        with a 100% failure rate and no error - the request succeeded, after all, it just
        said no. Without authentication configured, a load test completes in record time,
        reports a perfectly steady request rate, and measured nothing at all.

    So this script REFUSES to start unless it can see how authentication is configured.
    It then passes -SkipPreflight, because the preflight sends an unauthenticated request
    and would stop the run with exit code 2 for the very reason the run exists.

    Configuration comes from the .env file that run-test.ps1 already reads, so the
    credentials live in one ignored place rather than on every command line. See
    k6/.env.example for the three supported shapes:

      * AUTH_MODE=json-login   a bespoke JSON login endpoint (LOGIN_URL + account)
      * AUTH_MODE=oauth2       a standard OAuth2 token endpoint (AUTH_TOKEN_URL + client)
      * REQUEST_HEADERS=...    a static header, e.g. Authorization: Bearer ...

    For a multi-step flow rather than a single endpoint, use run-journey.ps1 instead.

.PARAMETER TargetUrl
    The PROTECTED endpoint, e.g. https://api.example.com/api/new-core/wallets.

.PARAMETER TestType
    smoke | load | stress | soak | spike | rate. Validated against the scenarios that
    actually exist on disk.

.PARAMETER Vus
    Convenience for TARGET_VUS. Ignored by rate, which is driven by TARGET_RPS.

.PARAMETER Duration
    Convenience for TEST_DURATION.

.PARAMETER EnvVars
    Any further scenario knobs, NAME=value, comma separated - the usual escape hatch.

.PARAMETER EnvFile
    Path to the .env file. Omit to use the default search (k6\.env, then .env).

.EXAMPLE
    pwsh -File k6/run-auth-test.ps1 -TestType load `
      -TargetUrl https://example.com/api/user/wallets `
      -Vus 20 -Duration 2m

.EXAMPLE
    # Rate test: fixed offered rate, so it can compare 1 pod against 3.
    pwsh -File k6/run-auth-test.ps1 -TestType rate `
      -TargetUrl https://example.com/api/user/wallets `
      -EnvVars TARGET_RPS=200,TEST_DURATION=1m
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateNotNullOrEmpty()]
    [string] $TargetUrl,

    [Parameter(Mandatory = $true, Position = 1)]
    [ValidateNotNullOrEmpty()]
    [string] $TestType,

    [int] $Vus,
    [string] $Duration,

    [string[]] $EnvVars = @(),
    [string] $EnvFile,
    [string] $ResultsRoot,

    [switch] $NoStack
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\scripts\lib\PerfTest.psm1') -Force

$repoRoot = Get-PerfTestRepoRoot
$scenariosDirectory = Join-Path $repoRoot 'k6\scripts'

# ---------------------------------------------------------------------------
# The test type must be real. Deriving the list from disk is the same rule the runner
# uses, so this cannot drift from the scenarios that exist.
# ---------------------------------------------------------------------------
$availableTypes = @(Get-PerfTestTypes -ScenariosDirectory $scenariosDirectory)
if ($availableTypes -notcontains $TestType) {
    throw ("Unknown -TestType '$TestType'. Available: {0}." -f ($availableTypes -join ', '))
}

if ($TestType -eq 'journey') {
    Write-Warning ("'journey' has its own front end that logs in once in setup() and skips the " +
        'per-VU auth this script relies on. Use k6/run-journey.ps1 instead.')
}

if ($TargetUrl -notmatch '^https?://') {
    throw "TargetUrl must start with http:// or https://, but got '$TargetUrl'."
}

# ---------------------------------------------------------------------------
# Resolve the environment exactly as run-test.ps1 will, so the check below sees what
# the scenario will actually see.
# ---------------------------------------------------------------------------
$envFileResult = Import-PerfTestEnvFile -ExplicitPath $EnvFile -SearchPaths @(
    (Join-Path $PSScriptRoot '.env')
    (Join-Path $repoRoot '.env')
)

$fileEnv = $envFileResult.Values
$commandLineEnv = ConvertTo-PerfTestEnvTable -EnvVars $EnvVars

$merged = @{}
foreach ($name in $fileEnv.Keys) { $merged[$name] = $fileEnv[$name] }
foreach ($name in $commandLineEnv.Keys) { $merged[$name] = $commandLineEnv[$name] }

function Get-Merged([string] $Name) {
    if ($merged.ContainsKey($Name)) { return "$($merged[$Name])" }
    return ''
}

# ---------------------------------------------------------------------------
# Refuse to run blind.
#
# Anything that reaches the target unauthenticated produces a fast, clean, meaningless
# run. Checking first turns that into a sentence explaining what to add.
# ---------------------------------------------------------------------------
$mode = Get-Merged 'AUTH_MODE'
$username = Get-Merged 'AUTH_USERNAME'
if (-not $username) { $username = Get-Merged 'JOURNEY_USERNAME' }
$password = Get-Merged 'AUTH_PASSWORD'
if (-not $password) { $password = Get-Merged 'JOURNEY_PASSWORD' }

$authDescription = ''

if ((Get-Merged 'REQUEST_HEADERS') -match '(?i)authorization\s*:') {
    $authDescription = 'a static Authorization header in REQUEST_HEADERS'
}
elseif ($mode -match '(?i)^(off|none|disabled)$') {
    $authDescription = ''
}
elseif ($mode -match '(?i)^json-login$' -and (Get-Merged 'LOGIN_URL')) {
    if ($username -and $password) {
        $authDescription = "a JSON login at $(Get-Merged 'LOGIN_URL') as $username"
    }
}
elseif (Get-Merged 'AUTH_TOKEN_URL') {
    $authDescription = "an OAuth2 token endpoint at $(Get-Merged 'AUTH_TOKEN_URL')"
}

if (-not $authDescription) {
    $source = if ($envFileResult.Path) { $envFileResult.Path } else { '(no environment file found)' }
    throw ("Refusing to run: no authentication is configured, so every request would be a 401 " +
        "that k6 reports as a fast, successful-looking run.`n`n" +
        "Environment file: $source`n" +
        "AUTH_MODE       : $(if ($mode) { $mode } else { '(not set)' })`n`n" +
        "Add one of these to the environment file:`n`n" +
        "  # a bespoke JSON login endpoint`n" +
        "  AUTH_MODE=json-login`n" +
        "  LOGIN_URL=https://idp.example.com/accounts/login`n" +
        "  JOURNEY_USERNAME=someone@example.com`n" +
        "  JOURNEY_PASSWORD=...`n`n" +
        "  # a standard OAuth2 endpoint`n" +
        "  AUTH_MODE=oauth2`n" +
        "  AUTH_TOKEN_URL=https://idp.example.com/connect/token`n" +
        "  AUTH_CLIENT_ID=my-client`n" +
        "  AUTH_CLIENT_SECRET=...`n`n" +
        "  # or a static header`n" +
        "  REQUEST_HEADERS=Authorization: Bearer eyJ...`n")
}

Write-Host ''
Write-Host 'Authenticated load test' -ForegroundColor Cyan
Write-Host "  target     : $TargetUrl"
Write-Host "  test type  : $TestType"
Write-Host "  auth       : $authDescription"
if ($envFileResult.Path) { Write-Host "  env file   : $($envFileResult.Path)" }
Write-Host ''
Write-Host 'The preflight is skipped on purpose: it sends an unauthenticated request, gets a 401,' -ForegroundColor DarkGray
Write-Host 'and would stop the run before it started.' -ForegroundColor DarkGray
Write-Host ''

# A static token cannot be refreshed. Worth saying out loud before a long run rather
# than diagnosing 401s at hour nine.
if ($authDescription -like 'a static*') {
    Write-Warning ('REQUEST_HEADERS carries a static token, which cannot be renewed. A run ' +
        'longer than the token''s lifetime will start returning 401s partway through. Use ' +
        'AUTH_MODE=json-login or AUTH_MODE=oauth2 for a long soak.')
}

# ---------------------------------------------------------------------------
# Hand off. -SkipPreflight is the whole point of this wrapper, so it is not optional.
# ---------------------------------------------------------------------------
$knobs = @()
if ($PSBoundParameters.ContainsKey('Vus')) { $knobs += "TARGET_VUS=$Vus" }
if ($Duration) { $knobs += "TEST_DURATION=$Duration" }
foreach ($entry in $EnvVars) { $knobs += $entry }

$runnerArguments = @{
    TargetUrl     = $TargetUrl
    TestType      = $TestType
    SkipPreflight = $true
}

if ($knobs.Count -gt 0) { $runnerArguments.EnvVars = $knobs }
if ($envFileResult.Path) { $runnerArguments.EnvFile = $envFileResult.Path }
if ($ResultsRoot) { $runnerArguments.ResultsRoot = $ResultsRoot }
if ($NoStack) { $runnerArguments.NoStack = $true }

& (Join-Path $PSScriptRoot 'run-test.ps1') @runnerArguments
exit $LASTEXITCODE
