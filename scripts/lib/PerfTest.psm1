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
    'Get-PerfTestGitRevision',
    'Invoke-Kubectl'
)
