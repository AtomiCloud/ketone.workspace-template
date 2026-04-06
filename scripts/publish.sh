#!/usr/bin/env bash
set -euo pipefail
[ "${CYAN_TOKEN:-}" = '' ] && echo "CYAN_TOKEN not set" && exit 1
[ "${IMAGE_VERSION:-}" = '' ] && echo "IMAGE_VERSION not set" && exit 1
[ "${DOMAIN:-}" = '' ] && echo "DOMAIN not set" && exit 1
[ "${GITHUB_REPO_REF:-}" = '' ] && echo "GITHUB_REPO_REF not set" && exit 1
DOMAIN="$(echo "${DOMAIN}" | tr '[:upper:]' '[:lower:]')"
export DOMAIN
GITHUB_REPO_REF="$(echo "${GITHUB_REPO_REF}" | tr '[:upper:]' '[:lower:]')"
export GITHUB_REPO_REF
COMMIT_SHA="${IMAGE_VERSION%%-*}"
BRANCH_SLUG="${IMAGE_VERSION#*-}"
BRANCH_SLUG="${BRANCH_SLUG:0:16}"
shopt -s extglob
BRANCH_SLUG="${BRANCH_SLUG%%+([-_.])}"
IMAGE_VERSION="${COMMIT_SHA:0:6}-${BRANCH_SLUG}"
COMMIT_MSG="$(git log -1 --pretty=%B | head -c 256)"
cyanprint push --token "${CYAN_TOKEN}" --message "${COMMIT_MSG}" template --build "${IMAGE_VERSION}"
