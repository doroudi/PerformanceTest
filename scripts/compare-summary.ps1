<#
.SYNOPSIS
    Compares a run's summary.json against an accepted baseline, and fails when the
    system got slower.

.DESCRIPTION
    A performance number on its own cannot answer "is this release worse than the
    last one?" - that needs a recorded baseline. This is the gate: it reads the
    summary.json written by scripts/deploy-and-test.ps1 (or k6/run-test.ps1),
    compares the metrics that matter against baselines/<test>.json, and exits
    non-zero when something regressed beyond the tolerance.

    Which way is "worse" depends on the metric: latency, error rate and TTFB going
    up is bad; throughput and check pass rate going down is bad. Improvements always
    pass, whatever the tolerance.

.PARAMETER Current
    summary.json (or the run directory) from the run you just did.

.PARAMETER Baseline
    The accepted baseline, e.g. baselines/load.json. Use -Update to (re)record it.

.PARAMETER TolerancePercent
    How much worse than the baseline is still acceptable. Default 10%.

    Do not set this to 1% and expect a stable gate: run-to-run variance on real
    infrastructure is larger than that, and a gate that cries wolf gets ignored.
    If you need tighter numbers, first make the environment quieter (dedicated
    nodes, fixed clocks/CPU pinning, no other tenants), then tighten.

.PARAMETER Update
    Accept the current run as the new baseline, and exit 0.

.EXAMPLE
    ./scripts/compare-summary.ps1 -Current ./results/20250101-120000-load -Baseline ./baselines/load.json

.EXAMPLE
    ./scripts/compare-summary.ps1 -Current ./results/latest.txt -Baseline ./baselines/smoke.json -Update
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string] $Current,

    [Parameter(Mandatory = $true, Position = 1)]
    [string] $Baseline,

    [double] $TolerancePercent = 10,

    [switch] $Update
)

$ErrorActionPreference = 'Stop'

function Resolve-SummaryPath {
    <# Accept a summary.json, a run directory, or results/latest.txt. #>
    param([Parameter(Mandatory = $true)][string] $Path)

    # A baseline does not exist yet the first time it is recorded, so a missing
    # path is resolved rather than rejected here.
    if (-not (Test-Path $Path)) {
        if ([System.IO.Path]::IsPathRooted($Path)) { return $Path }
        return [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $Path))
    }

    $resolved = (Resolve-Path $Path).Path

    if (Test-Path $resolved -PathType Container) {
        return (Join-Path $resolved 'summary.json')
    }

    if ((Split-Path -Leaf $resolved) -eq 'latest.txt') {
        $runDirectory = (Get-Content $resolved -Raw).Trim()
        return (Join-Path $runDirectory 'summary.json')
    }

    return $resolved
}

function Read-Summary {
    param([Parameter(Mandatory = $true)][string] $Path)

    if (-not (Test-Path $Path -PathType Leaf)) {
        throw "Summary file not found: $Path"
    }

    $summary = Get-Content -Path $Path -Raw | ConvertFrom-Json
    if (-not ($summary.PSObject.Properties['schema'])) {
        throw "$Path does not look like a perf-test-kit summary (no 'schema' property)."
    }

    return $summary
}

function Get-ValueByPath {
    <# Read a nested property by dotted path; property names may contain punctuation like p(95). #>
    param(
        [AllowNull()] $Object,
        [Parameter(Mandatory = $true)][string] $Path
    )

    $current = $Object
    foreach ($segment in $Path.Split('.')) {
        if ($null -eq $current) { return $null }
        $property = $current.PSObject.Properties[$segment]
        if (-not $property) { return $null }
        $current = $property.Value
    }

    return $current
}

function Format-MetricValue {
    param(
        [AllowNull()] $Value,
        [Parameter(Mandatory = $true)][string] $Unit
    )

    if ($null -eq $Value) { return 'n/a' }
    switch ($Unit) {
        'ratio' { return ('{0:N3}%' -f ([double]$Value * 100)) }
        'perSecond' { return ('{0:N2}/s' -f [double]$Value) }
        default { return ('{0:N2} ms' -f [double]$Value) }
    }
}

$currentPath = Resolve-SummaryPath -Path $Current
$baselinePath = Resolve-SummaryPath -Path $Baseline

# ---------------------------------------------------------------------------
# Record mode.
# ---------------------------------------------------------------------------
if ($Update) {
    $candidate = Read-Summary -Path $currentPath
    if (-not $candidate.thresholds_all_ok) {
        Write-Host ''
        Write-Warning 'Refusing to record a baseline from a run whose thresholds failed:'
        @($candidate.failed_thresholds) | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
        Write-Host ''
        Write-Host 'Fix the failure, or copy the summary over the baseline yourself if you really mean to accept it.'
        exit 1
    }

    $baselineDirectory = Split-Path -Parent $baselinePath
    if ($baselineDirectory -and -not (Test-Path $baselineDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $baselineDirectory -Force | Out-Null
    }

    Copy-Item -Path $currentPath -Destination $baselinePath -Force

    # Carry the provenance of the run alongside the baseline: a baseline with no
    # record of which build produced it is not much better than no baseline.
    $metaSource = Join-Path (Split-Path -Parent $currentPath) 'meta.json'
    if (Test-Path $metaSource -PathType Leaf) {
        Copy-Item -Path $metaSource -Destination (Join-Path $baselineDirectory 'meta.json') -Force
    }

    Write-Host "Baseline recorded: $baselinePath" -ForegroundColor Green
    Write-Host ("  test type : {0}" -f $candidate.test_type)
    Write-Host ("  target    : {0}" -f $candidate.target_url)
    if ($candidate.metrics.http_req_duration) {
        Write-Host ("  p95 / p99 : {0:N2} ms / {1:N2} ms" -f `
                [double]$candidate.metrics.http_req_duration.'p(95)', `
                [double]$candidate.metrics.http_req_duration.'p(99)')
    }
    exit 0
}

# ---------------------------------------------------------------------------
# Compare mode.
# ---------------------------------------------------------------------------
$currentSummary = Read-Summary -Path $currentPath
$baselineSummary = Read-Summary -Path $baselinePath

Write-Host ''
Write-Host 'Baseline comparison' -ForegroundColor Cyan
Write-Host "  current  : $currentPath"
Write-Host "  baseline : $baselinePath"
Write-Host ("  tolerance: {0:N1}% worse is still acceptable" -f $TolerancePercent)

$baselineMetaPath = Join-Path (Split-Path -Parent $baselinePath) 'meta.json'
if (Test-Path $baselineMetaPath -PathType Leaf) {
    $baselineMeta = Get-Content -Path $baselineMetaPath -Raw | ConvertFrom-Json
    Write-Host ("  baseline was recorded from image '{0}' (git {1})" -f $baselineMeta.api_image, $baselineMeta.git_revision) -ForegroundColor DarkGray
}

$specs = @(
    [pscustomobject]@{ Label = 'p95 latency'; Path = 'metrics.http_req_duration.p(95)'; Worse = 'higher'; Unit = 'ms' }
    [pscustomobject]@{ Label = 'p99 latency'; Path = 'metrics.http_req_duration.p(99)'; Worse = 'higher'; Unit = 'ms' }
    [pscustomobject]@{ Label = 'avg latency'; Path = 'metrics.http_req_duration.avg'; Worse = 'higher'; Unit = 'ms' }
    [pscustomobject]@{ Label = 'TTFB p95'; Path = 'metrics.http_req_waiting.p(95)'; Worse = 'higher'; Unit = 'ms' }
    [pscustomobject]@{ Label = 'error rate'; Path = 'metrics.http_req_failed.rate'; Worse = 'higher'; Unit = 'ratio' }
    [pscustomobject]@{ Label = 'throughput'; Path = 'metrics.http_reqs.rate'; Worse = 'lower'; Unit = 'perSecond' }
    [pscustomobject]@{ Label = 'check pass rate'; Path = 'checks.rate'; Worse = 'lower'; Unit = 'ratio' }
)

$failures = @()
$rows = @()

foreach ($spec in $specs) {
    $baselineValue = Get-ValueByPath -Object $baselineSummary -Path $spec.Path
    $currentValue = Get-ValueByPath -Object $currentSummary -Path $spec.Path

    if ($null -eq $baselineValue -or $null -eq $currentValue) {
        $rows += [pscustomobject]@{
            Label    = $spec.Label
            Baseline = Format-MetricValue -Value $baselineValue -Unit $spec.Unit
            Current  = Format-MetricValue -Value $currentValue -Unit $spec.Unit
            Delta    = 'skipped'
            Verdict  = 'n/a'
        }
        continue
    }

    $baselineNumber = [double]$baselineValue
    $currentNumber = [double]$currentValue
    $deltaText = 'n/a'
    $regressed = $false

    if ($baselineNumber -eq 0) {
        # A metric that used to be zero cannot have a percentage change. Going from
        # zero errors to some errors is the clearest regression there is.
        if ($spec.Worse -eq 'higher' -and $currentNumber -gt 0) {
            $deltaText = 'new'
            $regressed = $true
        }
        else {
            $deltaText = '0'
        }
    }
    else {
        $deltaPercent = (($currentNumber - $baselineNumber) / $baselineNumber) * 100
        $deltaText = ('{0:N1}%' -f $deltaPercent)
        if ($spec.Worse -eq 'higher' -and $deltaPercent -gt $TolerancePercent) { $regressed = $true }
        if ($spec.Worse -eq 'lower' -and $deltaPercent -lt (0 - $TolerancePercent)) { $regressed = $true }
    }

    if ($regressed) {
        $failures += ("{0} regressed: {1} -> {2} ({3})" -f `
                $spec.Label, (Format-MetricValue -Value $baselineValue -Unit $spec.Unit), (Format-MetricValue -Value $currentValue -Unit $spec.Unit), $deltaText)
    }

    $rows += [pscustomobject]@{
        Label    = $spec.Label
        Baseline = Format-MetricValue -Value $baselineValue -Unit $spec.Unit
        Current  = Format-MetricValue -Value $currentValue -Unit $spec.Unit
        Delta    = $deltaText
        Verdict  = if ($regressed) { 'FAIL' } else { 'ok' }
    }
}

Write-Host ''
Write-Host ('{0,-18} {1,14} {2,14} {3,10} {4,6}' -f 'metric', 'baseline', 'current', 'delta', 'result')
Write-Host ('-' * 68)

foreach ($row in $rows) {
    $colour = if ($row.Verdict -eq 'FAIL') { 'Red' } elseif ($row.Verdict -eq 'n/a') { 'DarkGray' } else { 'Gray' }
    Write-Host ('{0,-18} {1,14} {2,14} {3,10} {4,6}' -f $row.Label, $row.Baseline, $row.Current, $row.Delta, $row.Verdict) -ForegroundColor $colour
}

# A threshold that used to pass and now does not is a regression regardless of how
# the averages moved.
if ($baselineSummary.thresholds_all_ok -and -not $currentSummary.thresholds_all_ok) {
    $failures += ('thresholds now failing: {0}' -f (@($currentSummary.failed_thresholds) -join '; '))
}

Write-Host ''

if ($failures.Count -gt 0) {
    Write-Warning "Regression detected against the baseline:"
    $failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    Write-Host ''
    Write-Host 'If this is expected and accepted, record it as the new baseline:' -ForegroundColor Cyan
    Write-Host "  ./scripts/compare-summary.ps1 -Current `"$currentPath`" -Baseline `"$baselinePath`" -Update"
    exit 1
}

Write-Host 'No regression beyond tolerance.' -ForegroundColor Green
exit 0
