<#
Shared helpers for the k6 runners.

This module exists so that the two entry points - k6/run-test.ps1 (local
docker-compose authoring) and scripts/deploy-and-test.ps1 (Kubernetes runs) -
agree on three things that would otherwise drift apart:

  * which test types exist (read from the scenarios directory, so a `-TestType`
    that has no script fails with a useful message instead of a docker/kubectl
    error),
  * how a k6 summary is cut out of a log and turned into results/summary.json,
  * how files are written (UTF-8 without a BOM: a BOM in a YAML manifest makes
    kubectl fail with a bewildering parse error).
#>

$script:SummaryBeginMarker = '===K6_SUMMARY_JSON_BEGIN==='
$script:SummaryEndMarker = '===K6_SUMMARY_JSON_END==='
$script:SummarySchema = 'perftest.summary/v1'

function Get-PerfTestRepoRoot {
    <# The kit's root directory (the module lives in scripts/lib). #>
    [CmdletBinding()]
    param()

    return (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
}

function Get-PerfTestSummaryMarkers {
    [CmdletBinding()]
    param()

    return [pscustomobject]@{
        Begin  = $script:SummaryBeginMarker
        End    = $script:SummaryEndMarker
        Schema = $script:SummarySchema
    }
}

function Write-Utf8NoBom {
    <# Write a text file as UTF-8 with no byte order mark, creating parent directories. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string] $Content
    )

    $directory = Split-Path -Parent $Path
    if ($directory -and -not (Test-Path $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($false)))
    return $Path
}

function Get-PerfTestTypes {
    <#
    The available test types, derived from the scenario files on disk.

    Deriving them instead of hardcoding a ValidateSet is deliberate: a list in the
    script drifts from the directory, and `-TestType load` used to be accepted
    while no load-test.js existed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $ScenariosDirectory
    )

    if (-not (Test-Path $ScenariosDirectory -PathType Container)) {
        throw "Scenarios directory not found: $ScenariosDirectory"
    }

    return @(
        Get-ChildItem -Path $ScenariosDirectory -Filter '*-test.js' -File |
            Sort-Object Name |
            ForEach-Object { $_.Name -replace '-test\.js$', '' }
    )
}

function Resolve-PerfTestScenario {
    <# Resolve a test type to its scenario file, or fail listing what is available. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $TestType,
        [Parameter(Mandatory = $true)][string] $ScenariosDirectory
    )

    $available = Get-PerfTestTypes -ScenariosDirectory $ScenariosDirectory
    if ($available -notcontains $TestType) {
        throw ("Unknown test type '$TestType'. Available test types: {0}." -f ($available -join ', '))
    }

    return (Join-Path $ScenariosDirectory "$TestType-test.js")
}

function New-PerfTestRunDirectory {
    <#
    Create results/<utc timestamp>-<name>/ for one run.

    Every run gets its own directory so that a run can never overwrite the
    evidence from the run before it, and results/latest.txt points at the newest
    one so the compare script can be called without hunting for a path.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $ResultsRoot,
        [Parameter(Mandatory = $true)][string] $Name
    )

    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
    $safeName = ($Name -replace '[^A-Za-z0-9\-_]', '-')
    $runDirectory = Join-Path $ResultsRoot "$stamp-$safeName"

    if (-not (Test-Path $runDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $runDirectory -Force | Out-Null
    }

    Write-Utf8NoBom -Path (Join-Path $ResultsRoot 'latest.txt') -Content $runDirectory | Out-Null
    return $runDirectory
}

function Get-K6SummaryJsonFromText {
    <#
    Cut the machine-readable summary out of k6 output and return it as raw JSON text.

    k6/scripts/lib/summary.js prints the JSON between two markers, so the same
    parsing works for `docker compose run` output and for `kubectl logs`. Returning
    the text (rather than the parsed object) lets callers archive exactly what was
    measured, without a round-trip through PowerShell's serializer.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][AllowNull()][string] $Text
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        throw "k6 produced no output, so there is no summary to read. Check the raw log for an image pull or startup failure."
    }

    $pattern = '(?s)' + [regex]::Escape($script:SummaryBeginMarker) + '(?<json>.*?)' + [regex]::Escape($script:SummaryEndMarker)
    $match = [regex]::Match($Text, $pattern)

    if (-not $match.Success) {
        $tail = ($Text -split "`r?`n" | Select-Object -Last 20) -join "`n"
        throw ("k6 output contained no summary block ({0} ... {1}). The run probably failed before the end-of-test summary.`nLast lines of output:`n{2}" -f `
                $script:SummaryBeginMarker, $script:SummaryEndMarker, $tail)
    }

    return $match.Groups['json'].Value.Trim()
}

function Get-K6SummaryFromText {
    <# Same as Get-K6SummaryJsonFromText, but parsed into an object. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][AllowNull()][string] $Text
    )

    $json = Get-K6SummaryJsonFromText -Text $Text

    try {
        return ($json | ConvertFrom-Json)
    }
    catch {
        throw ("The summary block was found but is not valid JSON: {0}" -f $_.Exception.Message)
    }
}

function Get-K6SummaryFromFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $Path
    )

    if (-not (Test-Path $Path -PathType Leaf)) {
        throw "Log file not found: $Path"
    }

    return (Get-K6SummaryFromText -Text (Get-Content -Path $Path -Raw))
}

function Write-PerfTestMetadata {
    <# Record what was run, against what, and with which knobs - next to the results. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][hashtable] $Data
    )

    $json = $Data | ConvertTo-Json -Depth 8
    return (Write-Utf8NoBom -Path $Path -Content $json)
}

function ConvertTo-PerfTestEnvTable {
    <#
    Parse a -EnvVars argument into a name -> value table.

    Both documented invocation styles must behave identically:

        # in-process: PowerShell splits the commas itself
        ./k6/run-test.ps1  -EnvVars TARGET_VUS=20,HOLD_DURATION=5m

        # pwsh -File: PowerShell does NOT split the commas
        pwsh -File k6/run-test.ps1 -EnvVars TARGET_VUS=20,HOLD_DURATION=5m

    The second form is the one every README example uses, and it delivers the
    whole "TARGET_VUS=20,HOLD_DURATION=5m" as a SINGLE array element. A runner
    that only iterated the array therefore set TARGET_VUS to the string
    "20,HOLD_DURATION=5m" and handed k6 a number that was not a number - which
    surfaced as `TARGET_VUS must be a non-negative number, but got
    "20,HOLD_DURATION=5m"`, a message that points at the scenario file rather
    than at the argument parsing. Splitting every element on commas makes the
    two styles agree.

    Consequence worth knowing: a value cannot itself contain a comma. None of
    the scenario knobs do.
    #>
    [CmdletBinding()]
    param(
        [string[]] $EnvVars = @()
    )

    $table = @{}
    foreach ($element in $EnvVars) {
        foreach ($part in ("$element" -split ',')) {
            $entry = $part.Trim()
            if ($entry -eq '') {
                continue
            }
            if ($entry -notmatch '^(?<name>[A-Za-z_][A-Za-z0-9_]*)=(?<value>.*)$') {
                throw ("EnvVars entries must look like NAME=value, but got '{0}'. " +
                    'Separate several entries with commas: -EnvVars TARGET_VUS=20,HOLD_DURATION=5m' -f $entry)
            }
            $table[$Matches['name']] = $Matches['value']
        }
    }

    return $table
}

function Get-PerfTestSummaryWindow {
    <#
    Read the run's started_at / ended_at out of a summary.json WITHOUT letting
    PowerShell coerce them into [datetime].

    Why this exists: ConvertFrom-Json silently converts an ISO 8601 string to a
    [datetime]. That value then stringifies in the current culture - on this
    machine "2026-10-01T08:39:30.123Z" became "10/01/2026 08:39:30" - and
    re-parsing a string with no zone designator left makes it LOCAL time. The
    effect was a Grafana link whose time window was shifted by the machine's UTC
    offset (+03:30 here): the run's metrics existed, but the dashboard was
    looking 3.5 hours earlier and every panel read "No data".

    Regex against the raw file keeps exactly the string k6 wrote. Returns $null
    rather than throwing when the fields are absent or unparseable, so callers
    can fall back.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $Path
    )

    if (-not (Test-Path $Path -PathType Leaf)) {
        return $null
    }

    $text = Get-Content -Path $Path -Raw
    $startMatch = [regex]::Match($text, '"started_at"\s*:\s*"(?<v>[^"]+)"')
    $endMatch = [regex]::Match($text, '"ended_at"\s*:\s*"(?<v>[^"]+)"')
    if (-not $startMatch.Success -or -not $endMatch.Success) {
        return $null
    }

    $startedAt = [DateTimeOffset]::MinValue
    $endedAt = [DateTimeOffset]::MinValue
    $startOk = [DateTimeOffset]::TryParse($startMatch.Groups['v'].Value, [ref]$startedAt)
    $endOk = [DateTimeOffset]::TryParse($endMatch.Groups['v'].Value, [ref]$endedAt)
    if (-not $startOk -or -not $endOk) {
        return $null
    }

    return [pscustomobject]@{
        StartedAt = $startedAt
        EndedAt   = $endedAt
    }
}

function Get-PerfTestGitRevision {
    [CmdletBinding()]
    param()

    $command = Get-Command git -ErrorAction SilentlyContinue
    if (-not $command) {
        return $null
    }

    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $revision = & git -C (Get-PerfTestRepoRoot) rev-parse HEAD 2>&1
        $code = $LASTEXITCODE
        if ($code -ne 0) { return $null }
        return ("$revision").Trim()
    }
    finally {
        $ErrorActionPreference = $previous
    }
}

function Invoke-Kubectl {
    <#
    Run kubectl and return its output as string lines.

    stderr is folded into the returned lines rather than being turned into
    terminating errors: with $ErrorActionPreference = 'Stop', `2>&1` on a native
    command can throw a NativeCommandError before we ever get to inspect the exit
    code, which would hide kubectl's actual message.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string[]] $Arguments,
        [switch] $AllowFailure
    )

    if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
        throw "kubectl was not found on PATH. Install it, or use the local docker-compose path (k6/run-test.ps1)."
    }

    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $raw = & kubectl @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previous
    }

    $lines = @($raw | ForEach-Object { "$_" })

    if ($exitCode -ne 0 -and -not $AllowFailure) {
        throw ("kubectl {0} failed with exit code {1}.`n{2}" -f ($Arguments -join ' '), $exitCode, ($lines -join "`n"))
    }

    return , $lines
}

Export-ModuleMember -Function @(
    'Get-PerfTestRepoRoot',
    'Get-PerfTestSummaryMarkers',
    'Write-Utf8NoBom',
    'Get-PerfTestTypes',
    'Resolve-PerfTestScenario',
    'New-PerfTestRunDirectory',
    'Get-K6SummaryJsonFromText',
    'Get-K6SummaryFromText',
    'Get-K6SummaryFromFile',
    'Write-PerfTestMetadata',
    'ConvertTo-PerfTestEnvTable',
    'Get-PerfTestSummaryWindow',
    'Get-PerfTestGitRevision',
    'Invoke-Kubectl'
)
