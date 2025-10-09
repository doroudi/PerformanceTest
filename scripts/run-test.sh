#!/bin/bash

set -e

TEST_TYPE=${1:-smoke}
TEST_SCRIPT=${2:-"tests/${TEST_TYPE}-test.js"}
K6_NAMESPACE="perf-test"

echo "🧪 Running $TEST_TYPE test..."

# Build K6 Docker image
docker build -t k6-custom -f k6/Dockerfile .

# Create K6 job
cat <<EOF | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: k6-test-${TEST_TYPE}
  namespace: ${K6_NAMESPACE}
spec:
  template:
    spec:
      containers:
      - name: k6
        image: k6-custom
        imagePullPolicy: Never
        command: ["k6", "run", "/scripts/${TEST_SCRIPT}"]
        env:
        - name: TEST_TYPE
          value: "${TEST_TYPE}"
        resources:
          requests:
            memory: "512Mi"
            cpu: "500m"
          limits:
            memory: "1Gi"
            cpu: "1000m"
      restartPolicy: Never
  backoffLimit: 0
EOF

# Wait for job completion
echo "⏳ Waiting for test to complete..."
kubectl wait --for=condition=complete --timeout=1800s job/k6-test-${TEST_TYPE} -n ${K6_NAMESPACE}

# Get logs
echo "📊 Test Results:"
kubectl logs job/k6-test-${TEST_TYPE} -n ${K6_NAMESPACE}

# Cleanup job
kubectl delete job k6-test-${TEST_TYPE} -n ${K6_NAMESPACE}

echo "✅ Test completed!"