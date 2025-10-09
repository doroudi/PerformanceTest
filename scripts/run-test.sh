#!/usr/bin/env bash
#
# Thin wrapper: the Kubernetes runner is implemented once, in PowerShell
# (scripts/deploy-and-test.ps1), so the two front-ends cannot drift apart. They
# used to be separate scripts that disagreed about waiting, cleanup and defaults.
#
# Requires PowerShell 7+ (`pwsh`), available on Linux and macOS:
#   https://learn.microsoft.com/powershell/scripting/install/installing-powershell
#
# Usage:
#   ./scripts/run-test.sh -TargetUrl http://api-service:8080/api/health -TestType smoke
#   ./scripts/run-test.sh -TargetUrl http://api-service:8080/api/orders -TestType load \
#       -EnvVars TARGET_VUS=200,HOLD_DURATION=15m
#
# Every argument is passed straight through, so see the runner's own help:
#   pwsh -File scripts/deploy-and-test.ps1 -?

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v pwsh >/dev/null 2>&1; then
    echo "pwsh (PowerShell 7+) is required: this wrapper only forwards to the PowerShell runner." >&2
    echo "Install it, or run the equivalents by hand:" >&2
    echo "  kubectl apply -k k8s/overlays/local" >&2
    echo "  kubectl apply -f <job manifest written by the runner>" >&2
    exit 1
fi

exec pwsh -NoProfile -File "${script_dir}/deploy-and-test.ps1" "$@"
