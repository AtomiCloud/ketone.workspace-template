#!/usr/bin/env bash
set -euo pipefail

export INFISICAL_API_URL="https://secrets.atomi.cloud"

# Idempotent: only log in if we aren't already authenticated.
if infisical user get token --silent >/dev/null 2>&1; then
  echo "✓ Infisical already logged in"
else
  echo "→ Logging into Infisical..."
  infisical login
fi
