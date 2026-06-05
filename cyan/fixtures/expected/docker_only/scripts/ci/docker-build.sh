#!/usr/bin/env bash
set -euo pipefail

PLATFORM="test-platform"
SERVICE="test-service"

echo "Building Docker image for ${PLATFORM}/${SERVICE}"
docker build -t "${PLATFORM}-${SERVICE}:latest" -f infra/Dockerfile .
