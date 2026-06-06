#!/usr/bin/env bash
set -euo pipefail

# CD (release): re-tag the already-built commit image to the release semver WITHOUT
# rebuilding, using buildx imagetools (manifest-level, multi-arch safe). Runs once per image
# (driven by a workflow matrix), so there is no cap on the number of images re-tagged.
#
# Usage: cd-docker.sh <release-version>   (e.g. v1.2.3; falls back to GITHUB_REF_NAME)

: "${DOMAIN:?'DOMAIN' env var not set}"
: "${GITHUB_REPO_REF:?'GITHUB_REPO_REF' env var not set}"
: "${GITHUB_SHA:?'GITHUB_SHA' env var not set}"
: "${DOCKER_USER:?'DOCKER_USER' env var not set}"
: "${DOCKER_PASSWORD:?'DOCKER_PASSWORD' env var not set}"

RELEASE_VERSION="${1:-${GITHUB_REF_NAME:-}}"
: "${RELEASE_VERSION:?'release version ($1 or GITHUB_REF_NAME) not set'}"

# The release tag points at a commit on the release branch; its CI image is <sha6>-<branch>.
LATEST_BRANCH="${LATEST_BRANCH:-main}"
CI_DOCKER_IMAGE="${CI_DOCKER_IMAGE:-test-platform-test-service}"

onExit() {
  rc="$?"
  [ "$rc" = '0' ] && echo "✅ Re-tagged image to ${RELEASE_VERSION}" || echo "❌ Failed to re-tag image"
}
trap onExit EXIT

echo "🔐 Logging into ${DOMAIN}..."
echo "${DOCKER_PASSWORD}" | docker login "${DOMAIN}" -u "${DOCKER_USER}" --password-stdin

SHA="$(echo "${GITHUB_SHA}" | head -c 6)"
IMAGE_VERSION="${SHA}-${LATEST_BRANCH}"

IMAGE_ID="$(echo "${DOMAIN}/${GITHUB_REPO_REF}/${CI_DOCKER_IMAGE}" | tr '[:upper:]' '[:lower:]')"

echo "🏷️ Re-tagging ${IMAGE_ID}:${IMAGE_VERSION} -> ${IMAGE_ID}:${RELEASE_VERSION}"
docker buildx imagetools create \
  -t "${IMAGE_ID}:${RELEASE_VERSION}" \
  "${IMAGE_ID}:${IMAGE_VERSION}"
