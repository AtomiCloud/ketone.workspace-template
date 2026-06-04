#!/usr/bin/env bash
set -euo pipefail

PLATFORM="test-platform"
SERVICE="test-service"

echo "Linting Helm chart for ${PLATFORM}/${SERVICE}"
helm lint infra/root_chart
