#!/bin/bash

set -e

echo "🧹 Cleaning up resources..."

kubectl delete -f k8s/ --ignore-not-found=true
kubectl delete namespace perf-test --ignore-not-found=true

echo "✅ Cleanup completed!"