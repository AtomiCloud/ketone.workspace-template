#!/usr/bin/env bash
set -euo pipefail

PLATFORM="let__platform__"
SERVICE="let__service__"

echo "Building Docker image for ${PLATFORM}/${SERVICE}"
docker build -t "${PLATFORM}-${SERVICE}:latest" -f infra/Dockerfile .
