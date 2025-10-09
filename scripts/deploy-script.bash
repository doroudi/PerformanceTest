#!/bin/bash

set -e

echo "🚀 Deploying ASP.NET API to Kubernetes..."

# Create namespace
kubectl apply -f k8s/namespace.yaml

# Build and deploy your API (modify according to your build process)
# Example: 
# docker build -t your-aspnet-api:latest ../your-api-project
# kind load docker-image your-aspnet-api:latest  # if using kind

# Deploy API
kubectl apply -f k8s/api-deployment.yaml
kubectl apply -f k8s/api-service.yaml

# Wait for deployment to be ready
echo "⏳ Waiting for API to be ready..."
kubectl wait --for=condition=available --timeout=300s deployment/api-deployment -n perf-test

echo "✅ API deployed successfully!"