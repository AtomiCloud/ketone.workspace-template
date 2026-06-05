#!/usr/bin/env bash
set -euo pipefail

PLATFORM="let__platform__"
SERVICE="let__service__"

echo "Publishing Helm chart for ${PLATFORM}/${SERVICE}"
helm package infra/root_chart
