#!/usr/bin/env bash
set -euo pipefail

PLATFORM="let__platform__"
SERVICE="let__service__"

echo "Pushing Docker image for ${PLATFORM}/${SERVICE}"
docker push "${PLATFORM}-${SERVICE}:latest"
