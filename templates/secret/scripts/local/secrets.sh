#!/usr/bin/env bash
set -euo pipefail
INFISICAL_API_URL="https://secrets.atomi.cloud" infisical login
infisical run --env=dev -- true
