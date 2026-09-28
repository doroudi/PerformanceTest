#!/usr/bin/env bash
#
# Remove everything this kit deploys.
#
# Deleting the namespace removes the API deployment, the Service and any k6 Jobs
# in it. Results already written to results/ are local files and are left alone -
# they are the evidence, and are not something a cleanup script should decide to
# throw away.
#
# Usage:
#   ./scripts/cleanup.sh                 # deletes the perf-test namespace
#   ./scripts/cleanup.sh perf-test-2     # deletes a namespace you named yourself

set -euo pipefail

namespace="${1:-perf-test}"

if ! command -v kubectl >/dev/null 2>&1; then
    echo "kubectl was not found on PATH." >&2
    exit 1
fi

echo "Removing namespace '${namespace}' (API deployment, Service, k6 Jobs)..."
kubectl delete namespace "${namespace}" --ignore-not-found=true --wait=true

# The generated kustomize overlays are per-run scratch files.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
generated="${script_dir}/../k8s/.generated"
if [ -d "${generated}" ]; then
    echo "Removing generated overlays in ${generated}..."
    rm -rf "${generated}"
fi

echo "Cleanup completed. Local results in results/ were left in place."
