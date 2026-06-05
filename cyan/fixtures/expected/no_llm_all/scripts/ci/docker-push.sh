#!/usr/bin/env bash
set -euo pipefail

PLATFORM="test-platform"
SERVICE="test-service"

echo "Pushing Docker image for ${PLATFORM}/${SERVICE}"
docker push "${PLATFORM}-${SERVICE}:latest"
