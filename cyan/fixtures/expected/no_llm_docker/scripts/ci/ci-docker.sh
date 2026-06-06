#!/usr/bin/env bash
set -euo pipefail

# Per-commit CI: build and push a Docker image tagged by commit / branch / latest, using a
# cached buildx builder. Runs once per image (driven by a workflow matrix), so there is no
# cap on the number of images built per push.

: "${DOMAIN:?'DOMAIN' env var not set}"
: "${GITHUB_REPO_REF:?'GITHUB_REPO_REF' env var not set}"
: "${GITHUB_SHA:?'GITHUB_SHA' env var not set}"
: "${GITHUB_BRANCH:?'GITHUB_BRANCH' env var not set}"
: "${DOCKER_USER:?'DOCKER_USER' env var not set}"
: "${DOCKER_PASSWORD:?'DOCKER_PASSWORD' env var not set}"

# Per-image config (defaults target the single scaffold image).
CI_DOCKER_IMAGE="${CI_DOCKER_IMAGE:-test-platform-test-service}"
CI_DOCKER_CONTEXT="${CI_DOCKER_CONTEXT:-.}"
CI_DOCKERFILE="${CI_DOCKERFILE:-infra/Dockerfile}"
CI_DOCKER_PLATFORM="${CI_DOCKER_PLATFORM:-linux/amd64,linux/arm64}"
LATEST_BRANCH="${LATEST_BRANCH:-main}"

onExit() {
  rc="$?"
  [ "$rc" = '0' ] && echo "✅ Built and pushed image" || echo "❌ Failed to build/push image"
}
trap onExit EXIT

echo "🔐 Logging into ${DOMAIN}..."
echo "${DOCKER_PASSWORD}" | docker login "${DOMAIN}" -u "${DOCKER_USER}" --password-stdin

# Version: <sha6>-<branch slug>
SHA="$(echo "${GITHUB_SHA}" | head -c 6)"
BRANCH="$(echo "${GITHUB_BRANCH}" | sed 's#[/_.]#-#g; s/[^a-zA-Z0-9-]//g')"
IMAGE_VERSION="${SHA}-${BRANCH}"

IMAGE_ID="$(echo "${DOMAIN}/${GITHUB_REPO_REF}/${CI_DOCKER_IMAGE}" | tr '[:upper:]' '[:lower:]')"

COMMIT_REF="${IMAGE_ID}:${IMAGE_VERSION}"
BRANCH_REF="${IMAGE_ID}:${BRANCH}"
LATEST_REF="${IMAGE_ID}:latest"

echo "📝 Image: ${IMAGE_ID}"
echo "  commit: ${COMMIT_REF}"
echo "  branch: ${BRANCH_REF}"

tags=(-t "${COMMIT_REF}" -t "${BRANCH_REF}")
if [ "${BRANCH}" = "${LATEST_BRANCH}" ]; then
  echo "  latest: ${LATEST_REF}"
  tags+=(-t "${LATEST_REF}")
fi

echo "🔨 Building & pushing (cached)..."
docker buildx build \
  "${CI_DOCKER_CONTEXT}" \
  -f "${CI_DOCKERFILE}" \
  --platform="${CI_DOCKER_PLATFORM}" \
  --push \
  "${tags[@]}"
