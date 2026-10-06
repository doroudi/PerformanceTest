<#
.SYNOPSIS
    Keep the in-cluster Grafana (or Prometheus) reachable from this machine, across pod
    replacements and dropped connections.

.DESCRIPTION
    A NodePort is opened on the node network, not on your machine's loopback, so reaching
    the dashboard means a `kubectl port-forward`. That forward is fragile in three separate
    ways, all of them observed on a real cluster:

      * it is attached to the POD behind the Service, so replacing that pod ends it
        ("error: lost connection to pod"). Replacing the pod is what a dashboard change
        does, and what `scripts/deploy-observability.ps1` used to do on every run;
      * the stream to the API server can drop on its own - on Docker Desktop a long-lived
        connection is torn down with `wsasend: An existing connection was forcibly closed by
        the remote host`, which kubectl reports as `lost connection to pod` even though the
        pod is fine;
      * and the process can simply be closed, or die with the terminal it was started from.

    In every one of those cases the browser shows a connection error for a Grafana that is
    perfectly healthy, and the instinct is to debug Grafana. So this script supervises the
    forward instead: it runs kubectl, and when kubectl exits it says so and starts another
    one, on the same local port, until you stop it. The URL does not change.

.PARAMETER Service
    grafana (default) or prometheus.

.PARAMETER LocalPort
    The local port to forward to. Default: the first free port from 3001 (grafana) or 9091
    (prometheus) - deliberately NOT 3000/9090, which are what the compose stack publishes,
    because forwarding onto those shows the compose stack's own Grafana/Prometheus, which
    query a different Prometheus and report "No data" for a cluster run.

.PARAMETER Namespace
    Namespace of the observability stack. Default perf-observability.

.PARAMETER RetrySeconds
    How long to wait before reconnecting. Default 2.

.EXAMPLE
    pwsh -File scripts/expose-observability.ps1
    # Grafana on http://127.0.0.1:3001/d/k6-load-test, kept alive until Ctrl+C.

.EXAMPLE
    pwsh -File scripts/expose-observability.ps1 -Service prometheus -LocalPort 9091
#>
[CmdletBinding()]
param(
    [ValidateSet('grafana', 'prometheus')]
    [string] $Service = 'grafana',

    [int] $LocalPort = 0,

    [string] $Namespace = 'perf-observability',
    [int] $RetrySeconds = 2
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\PerfTest.psm1') -Force

if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
    throw 'kubectl was not found on PATH.'
}

$remotePort = if ($Service -eq 'grafana') { 3000 } else { 9090 }
$candidates = if ($Service -eq 'grafana') { @(3001, 3002, 3003, 3004) } else { @(9091, 9092, 9093, 9094) }

if ($LocalPort -le 0) {
    $LocalPort = Get-PerfTestFreeLocalPort -Candidate $candidates
    if (-not $LocalPort) {
        throw ("Every candidate local port is already in use ({0}). Stop whatever is listening, or pass -LocalPort " +
            'with a free one.' -f ($candidates -join ', '))
    }
}

$dashboardPath = if ($Service -eq 'grafana') { '/d/k6-load-test' } else { '/graph' }
$url = "http://127.0.0.1:$LocalPort$dashboardPath"

Write-Host ''
Write-Host ("{0} -> {1}" -f $Service, $url) -ForegroundColor Cyan
Write-Host ("  (forwarding to svc/{0}:{1} in {2}; this window must stay open - Ctrl+C to stop)" -f $Service, $remotePort, $Namespace) -ForegroundColor DarkGray
Write-Host ''

$attempt = 0

while ($true) {
    $attempt += 1

    $arguments = @('port-forward', '-n', $Namespace, "svc/$Service", "${LocalPort}:${remotePort}", '--address', '127.0.0.1')

    # kubectl's own output is kept, minus the line it prints for every single connection
    # ("Handling connection for 3001"), which is noise on a dashboard that polls. Errors are
    # the part worth reading, and they are what says why the forward ended.
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & kubectl @arguments 2>&1 | ForEach-Object {
            $line = "$_"
            if ($line -match 'Handling connection') { return }
            if ($line -match '(?i)error|unable|refused|lost connection') {
                Write-Host "  $line" -ForegroundColor DarkYellow
            }
            else {
                Write-Host "  $line" -ForegroundColor DarkGray
            }
        }
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previous
    }

    # Reached on Ctrl+C as well: the loop is the point, so say what happened and why the
    # link stopped working, rather than leaving a silent dead URL behind.
    Write-Host ("  the forward exited (code {0}). The usual cause is the pod behind the Service being replaced," -f $exitCode) -ForegroundColor DarkYellow
    Write-Host ("  or the stream to the API server dropping - neither of which means {0} is broken." -f $Service) -ForegroundColor DarkYellow
    Write-Host ("  reconnecting in ${RetrySeconds}s..." ) -ForegroundColor DarkGray

    Start-Sleep -Seconds $RetrySeconds

    if (Test-PerfTestTcpEndpoint -Port $LocalPort -TimeoutMilliseconds 500) {
        Write-Host '  reconnected.' -ForegroundColor Green
    }
    elseif ($attempt -gt 1) {
        Write-Host ("  not answering yet; if this repeats, check the stack: kubectl get pods -n $Namespace") -ForegroundColor DarkYellow
    }
}
