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

function Get-ConfigMapVersion {
    <# The ConfigMap's resourceVersion, or '' when it does not exist yet. #>
    param(
        [Parameter(Mandatory = $true)][string] $Name,
        [Parameter(Mandatory = $true)][string] $NamespaceName
    )

    $text = (& kubectl get configmap $Name -n $NamespaceName -o jsonpath='{.metadata.resourceVersion}' 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { return '' }
    return $text
}

# Read the versions BEFORE the apply, so the restart below can be skipped when nothing
# actually changed. `kubectl apply` of identical content is a no-op that leaves the
# resourceVersion alone, which makes it an exact signal for "the dashboards are the same".
$dashboardsBefore = Get-ConfigMapVersion -Name 'grafana-dashboards' -NamespaceName $Namespace
$provisioningBefore = Get-ConfigMapVersion -Name 'grafana-provisioning' -NamespaceName $Namespace

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
#
# That restart is expensive in a way the line above does not suggest: it replaces the pod,
# and everything attached to that pod dies with it - an open dashboard in a browser, and
# any `kubectl port-forward` pointing at the Service, whose next connection fails with
# `container not running` / `error: lost connection to pod`. This script used to restart
# unconditionally on every invocation, which on a real cluster meant a new Grafana pod on
# every single test run (nine ReplicaSets in one day, all but one scaled to zero). So:
# restart only when the dashboards or the provisioning actually changed.
$dashboardsAfter = Get-ConfigMapVersion -Name 'grafana-dashboards' -NamespaceName $Namespace
$provisioningAfter = Get-ConfigMapVersion -Name 'grafana-provisioning' -NamespaceName $Namespace

if ($dashboardsBefore -ne '' -and $provisioningBefore -ne '' -and
    $dashboardsBefore -eq $dashboardsAfter -and $provisioningBefore -eq $provisioningAfter) {
    Write-Host 'Dashboards and provisioning are unchanged, so Grafana was left running.' -ForegroundColor DarkGray
    Write-Host '  (Restarting it would replace the pod and drop anyone watching a dashboard, or any port-forward to it.)' -ForegroundColor DarkGray
}
else {
    & kubectl rollout restart deployment/grafana -n $Namespace 2>&1 | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
}

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

# A NodePort is opened on the NODE's network, not on the host's loopback.
#
# Docker Desktop's built-in Kubernetes does forward NodePorts to 127.0.0.1, which is why
# this script used to print that address unconditionally - but minikube's nodes live on
# 192.168.49.0/24 inside a VM, and kind's on a docker network, and neither is routable
# from the host. The URL was then a dead link, and a working Grafana looked broken. So ask
# whether the port actually answers, and when it does not, give a route that always works:
# the API server carries the TCP for a port-forward, and `minikube service` opens a tunnel.
$grafanaNodePort = 30030
$prometheusNodePort = 30090

$grafanaOnLoopback = Test-PerfTestTcpEndpoint -Port $grafanaNodePort
$prometheusOnLoopback = Test-PerfTestTcpEndpoint -Port $prometheusNodePort

# The local port for a port-forward must be free, and "free" includes "not already your
# compose Grafana": forwarding in-cluster Grafana onto a port the compose stack publishes
# shows the wrong dashboard against the wrong Prometheus.
$grafanaLocalPort = Get-PerfTestFreeLocalPort -Candidate @(3000, 3001, 3002, 3003)
$prometheusLocalPort = Get-PerfTestFreeLocalPort -Candidate @(9090, 9091, 9092, 9093)

if ($grafanaOnLoopback) {
    Write-Host "  Grafana    : http://127.0.0.1:$grafanaNodePort/d/k6-load-test"
}
else {
    Write-Host "  Grafana    : http://127.0.0.1:$grafanaLocalPort/d/k6-load-test   (after the port-forward below)"
}

if ($prometheusOnLoopback) {
    Write-Host "  Prometheus : http://127.0.0.1:$prometheusNodePort/graph"
}
else {
    Write-Host "  Prometheus : http://127.0.0.1:$prometheusLocalPort/graph   (after the port-forward below)"
}

if (-not $grafanaOnLoopback -or -not $prometheusOnLoopback) {
    Write-Host ''
    Write-Host "Neither $grafanaNodePort nor $prometheusNodePort answers on 127.0.0.1, which is expected on minikube and" -ForegroundColor DarkGray
    Write-Host 'kind: a NodePort is opened on the node network, not on your machine. Reach it with:' -ForegroundColor DarkGray
    Write-Host "  kubectl port-forward -n $Namespace svc/grafana ${grafanaLocalPort}:3000         # then http://127.0.0.1:$grafanaLocalPort" -ForegroundColor DarkGray
    Write-Host "  kubectl port-forward -n $Namespace svc/prometheus ${prometheusLocalPort}:9090  # then http://127.0.0.1:$prometheusLocalPort" -ForegroundColor DarkGray
    Write-Host "  minikube service -n $Namespace grafana                          # opens it for you, via a tunnel" -ForegroundColor DarkGray
}

Write-Host ('  Remote write endpoint for -PrometheusWriteUrl: http://prometheus.{0}.svc.cluster.local:9090/api/v1/write' -f $Namespace)
Write-Host ''
Write-Host 'Use 127.0.0.1, not localhost: Docker Desktop publishes on IPv6 as well and its IPv6 proxy hangs here.' -ForegroundColor DarkGray
