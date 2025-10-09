#!/usr/bin/env bash
#
# Deploy the API under test and stop, without running a scenario.
#
# Thin wrapper over the PowerShell runner's -DeployOnly mode, so the deployment
# settings (image, port, environment, probes, kustomize overlay generation) exist
# in exactly one place.
#
# Usage:
#   ./scripts/deploy-script.bash -Image my-api:1.4.2
#   ./scripts/deploy-script.bash -Image my-api:1.4.2 -Namespace perf-test -Replicas 2

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v pwsh >/dev/null 2>&1; then
    echo "pwsh (PowerShell 7+) is required: this wrapper only forwards to the PowerShell runner." >&2
    echo "Equivalent by hand: kubectl apply -k k8s/overlays/local" >&2
    exit 1
fi

exec pwsh -NoProfile -File "${script_dir}/deploy-and-test.ps1" -DeployOnly "$@"
