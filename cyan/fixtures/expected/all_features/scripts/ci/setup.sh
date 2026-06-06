#!/usr/bin/env bash
set -euo pipefail

# Install git hooks so commits are linted and formatted locally the same way CI checks them.
pre-commit install --install-hooks
pre-commit install --hook-type commit-msg
