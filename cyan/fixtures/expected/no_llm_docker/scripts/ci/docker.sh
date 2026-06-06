#!/usr/bin/env bash
set -euo pipefail

# Build and push a Docker image, tagged by commit / branch / latest, plus the release semver
# when a version arg is given. The buildx builder supplies the cache, so a release run is
# effectively a re-tag of the cached commit build.
#
# Usage: docker.sh [version]   (version empty on per-commit CI, set to the tag on release)

[[ -n "${DOMAIN:-}" ]] || { echo "❌ 'DOMAIN' env var not set"; exit 1; }
[[ -n "${GITHUB_REPO_REF:-}" ]] || { echo "❌ 'GITHUB_REPO_REF' env var not set"; exit 1; }
[[ -n "${GITHUB_SHA:-}" ]] || { echo "❌ 'GITHUB_SHA' env var not set"; exit 1; }
[[ -n "${GITHUB_BRANCH:-}" ]] || { echo "❌ 'GITHUB_BRANCH' env var not set"; exit 1; }
[[ -n "${DOCKER_USER:-}" ]] || { echo "❌ 'DOCKER_USER' env var not set"; exit 1; }
[[ -n "${DOCKER_PASSWORD:-}" ]] || { echo "❌ 'DOCKER_PASSWORD' env var not set"; exit 1; }
[[ -n "${LATEST_BRANCH:-}" ]] || { echo "❌ 'LATEST_BRANCH' env var not set"; exit 1; }
[[ -n "${CI_DOCKER_IMAGE:-}" ]] || { echo "❌ 'CI_DOCKER_IMAGE' env var not set"; exit 1; }
[[ -n "${CI_DOCKER_CONTEXT:-}" ]] || { echo "❌ 'CI_DOCKER_CONTEXT' env var not set"; exit 1; }
[[ -n "${CI_DOCKERFILE:-}" ]] || { echo "❌ 'CI_DOCKERFILE' env var not set"; exit 1; }
[[ -n "${CI_DOCKER_PLATFORM:-}" ]] || { echo "❌ 'CI_DOCKER_PLATFORM' env var not set"; exit 1; }

version="${1:-}"

echo "🔐 Logging into ${DOMAIN}..."
echo "${DOCKER_PASSWORD}" | docker login "${DOMAIN}" -u "${DOCKER_USER}" --password-stdin

IMAGE_ID="$(echo "${DOMAIN}/${GITHUB_REPO_REF}/${CI_DOCKER_IMAGE}" | tr '[:upper:]' '[:lower:]')"
SHA="$(echo "${GITHUB_SHA}" | head -c 6)"
BRANCH="${GITHUB_BRANCH//[._]/-}"
BRANCH="${BRANCH//\//-}"
IMAGE_VERSION="${SHA}-${BRANCH}"

# Conditional tags via substitution: latest on the default branch, semver on release.
latest_arg="$([[ "${BRANCH}" == "${LATEST_BRANCH}" ]] && echo "-t ${IMAGE_ID}:latest" || echo "")"
semver_arg="$([[ -n "${version}" ]] && echo "-t ${IMAGE_ID}:${version}" || echo "")"

echo "📝 Image: ${IMAGE_ID} (version ${IMAGE_VERSION}${version:+, release ${version}})"

echo "🔨 Building & pushing (cached)..."
# shellcheck disable=SC2086
docker buildx build \
  "${CI_DOCKER_CONTEXT}" \
  -f "${CI_DOCKERFILE}" \
  --platform="${CI_DOCKER_PLATFORM}" \
  --push \
  -t "${IMAGE_ID}:${IMAGE_VERSION}" \
  -t "${IMAGE_ID}:${BRANCH}" \
  ${latest_arg} ${semver_arg}

echo "✅ Pushed ${IMAGE_ID}"
