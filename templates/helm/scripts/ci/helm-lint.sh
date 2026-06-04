#!/usr/bin/env bash
set -euo pipefail

PLATFORM="let__platform__"
SERVICE="let__service__"

echo "Linting Helm chart for ${PLATFORM}/${SERVICE}"
helm lint infra/root_chart
