<#
.SYNOPSIS
    Deploy in-cluster Prometheus + Grafana for Kubernetes load-test runs.

.DESCRIPTION
    The compose stack (k6/docker-compose.yml) serves host-based runs. A run inside
    a cluster needs its own metrics stack, for one reason that is not cosmetic:
    only Prometheus running IN the cluster can scrape each node's kubelet, and
    without kubelet/cAdvisor there is no pod CPU, no memory working set and - the
    important one - no CPU-throttling series. Without those, "the test got slower"
    can never be answered with "because the pod hit its 2-CPU limit".

    Grafana is deployed here too rather than reusing the compose one, so its
    datasource is an in-cluster Service name and the provisioning files are used
    unchanged. The dashboards are the SAME JSON files from k6/grafana/dashboards,
    loaded into a ConfigMap, so there is one copy of each dashboard for both paths.

.PARAMETER Namespace
    Namespace for the observability stack. Default perf-observability.

.PARAMETER SkipWait
    Apply and return without waiting for rollouts.

.EXAMPLE
    pwsh -File scripts/deploy-observability.ps1
#>
[CmdletBinding()]
param(
    [string] $Namespace = 'perf-observability',
    [switch] $SkipWait
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\PerfTest.psm1') -Force

$repoRoot = Get-PerfTestRepoRoot
$observabilityDirectory = Join-Path $repoRoot 'k8s\observability'
$grafanaDirectory = Join-Path $repoRoot 'k6\grafana'
$dashboardsDirectory = Join-Path $grafanaDirectory 'dashboards'

foreach ($path in @($observabilityDirectory, $grafanaDirectory, $dashboardsDirectory)) {
    if (-not (Test-Path $path -PathType Container)) {
        throw "Not found: $path"
    }
}

if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
    throw 'kubectl was not found on PATH.'
}

# ---------------------------------------------------------------------------
# Grafana configuration as ConfigMaps, built from the same files the compose
# stack mounts. A ConfigMap key may not contain "/", and the dashboard provider
# wants its files in one flat directory anyway, so the two provisioning files are
# stored under flat keys and mounted individually with subPath in grafana.yaml.
# ---------------------------------------------------------------------------
$provisioningFiles = [ordered]@{
    'prometheus.yml' = Join-Path $grafanaDirectory 'provisioning\datasources\prometheus.yml'
    'dashboards.yml' = Join-Path $grafanaDirectory 'provisioning\dashboards\dashboards.yml'
}

foreach ($key in $provisioningFiles.Keys) {
    $path = $provisioningFiles[$key]
    if (-not (Test-Path $path -PathType Leaf)) {
        throw "Missing Grafana provisioning file: $path"
    }
}

$dashboardFiles = @(Get-ChildItem -Path $dashboardsDirectory -Filter '*.json' -File)
if ($dashboardFiles.Count -eq 0) {
    throw "No dashboard JSON found in $dashboardsDirectory. Grafana would provision an empty folder and every panel would read 'No data'."
}

Write-Host ('Creating config maps in {0}...' -f $Namespace) -ForegroundColor Cyan

function New-ConfigMapFromFiles {
    param(
        [Parameter(Mandatory = $true)][string] $Name,
        [Parameter(Mandatory = $true)][string[]] $FromFileArguments
    )

    # --dry-run=client then apply, rather than `kubectl create --dry-run | apply -f`:
    # create is not idempotent, so a second run of this script would fail with
    # AlreadyExists and leave the old ConfigMap in place.
    $arguments = @('create', 'configmap', $Name, '-n', $Namespace) + $FromFileArguments +
        @('--dry-run=client', '-o', 'yaml')

    $manifest = & kubectl @arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw ("kubectl create configmap $Name failed: {0}" -f ($manifest -join ' '))
    }

    $manifest | & kubectl apply -f - 2>&1 | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
    if ($LASTEXITCODE -ne 0) {
        throw "kubectl apply failed for config map $Name."
    }
}

$provisioningArguments = @()
foreach ($key in $provisioningFiles.Keys) {
    $provisioningArguments += ('--from-file={0}={1}' -f $key, $provisioningFiles[$key])
}

# The namespace must exist before a namespaced ConfigMap can be created, and the
# ConfigMaps must exist before the Grafana Deployment that mounts them.
& kubectl apply -f (Join-Path $observabilityDirectory 'namespace.yaml') 2>&1 |
    ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
if ($LASTEXITCODE -ne 0) {
    throw 'Could not create the observability namespace. Is kubectl pointed at a cluster?'
}

New-ConfigMapFromFiles -Name 'grafana-provisioning' -FromFileArguments $provisioningArguments

$dashboardArguments = @()
foreach ($file in $dashboardFiles) {
    $dashboardArguments += ('--from-file={0}={1}' -f $file.Name, $file.FullName)
}
New-ConfigMapFromFiles -Name 'grafana-dashboards' -FromFileArguments $dashboardArguments

Write-Host 'Applying Prometheus and Grafana...' -ForegroundColor Cyan
& kubectl apply -k $observabilityDirectory 2>&1 | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
if ($LASTEXITCODE -ne 0) {
    throw "kubectl apply -k $observabilityDirectory failed."
}

# A ConfigMap is mounted as a volume, so Grafana only sees a changed dashboard
# after it restarts - and it caches the provisioning files read at start-up.
& kubectl rollout restart deployment/grafana -n $Namespace 2>&1 | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }

if (-not $SkipWait) {
    Write-Host 'Waiting for Prometheus and Grafana...' -ForegroundColor Cyan
    foreach ($deployment in @('prometheus', 'grafana')) {
        & kubectl rollout status "deployment/$deployment" -n $Namespace --timeout=300s 2>&1 |
            ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
        if ($LASTEXITCODE -ne 0) {
            throw "deployment/$deployment did not become ready. Check: kubectl describe pods -n $Namespace"
        }
    }
}

Write-Host ''
Write-Host 'Observability stack is up:' -ForegroundColor Green
Write-Host '  Grafana    : http://127.0.0.1:30030/d/k6-load-test'
Write-Host '  Prometheus : http://127.0.0.1:30090/graph'
Write-Host ('  Remote write endpoint for -PrometheusWriteUrl: http://prometheus.{0}.svc.cluster.local:9090/api/v1/write' -f $Namespace)
Write-Host ''
Write-Host 'Use 127.0.0.1, not localhost: Docker Desktop publishes on IPv6 as well and its IPv6 proxy hangs here.' -ForegroundColor DarkGray
