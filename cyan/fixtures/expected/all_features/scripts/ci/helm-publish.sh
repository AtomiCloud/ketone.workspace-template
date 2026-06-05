#!/usr/bin/env bash
set -euo pipefail

PLATFORM="test-platform"
SERVICE="test-service"

echo "Publishing Helm chart for ${PLATFORM}/${SERVICE}"
helm package infra/root_chart
