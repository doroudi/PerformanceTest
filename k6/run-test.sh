#!/usr/bin/env bash
#
# Thin wrapper: the runner is implemented once, in PowerShell
# (k6/run-test.ps1), so the two front-ends cannot drift apart.
#
# Requires PowerShell 7+ (`pwsh`), which is available on Linux and macOS:
#   https://learn.microsoft.com/powershell/scripting/install/installing-powershell
#
# Usage:
#   ./k6/run-test.sh -TargetUrl http://host.docker.internal:5000/api/health -TestType smoke

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v pwsh >/dev/null 2>&1; then
    echo "pwsh (PowerShell 7+) is required: this wrapper only forwards to the PowerShell runner." >&2
    echo "Install it, or call docker compose directly:" >&2
    echo "  docker compose -f '${script_dir}/docker-compose.yml' run --rm -e TARGET_URL=<url> k6 run /scripts/smoke-test.js" >&2
    exit 1
fi

exec pwsh -NoProfile -File "${script_dir}/run-test.ps1" "$@"
