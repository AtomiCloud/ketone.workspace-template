#!/usr/bin/env bash

# check for necessary env vars
[ "${DOMAIN}" = '' ] && echo "❌ 'DOMAIN' env var not set" && exit 1
[ "${GITHUB_REPO_REF}" = '' ] && echo "❌ 'GITHUB_REPO_REF' env var not set" && exit 1
[ "${GITHUB_SHA}" = '' ] && echo "❌ 'GITHUB_SHA' env var not set" && exit 1
[ "${GITHUB_BRANCH}" = '' ] && echo "❌ 'GITHUB_BRANCH' env var not set" && exit 1

[ "${CI_DOCKER_IMAGE}" = '' ] && echo "❌ 'CI_DOCKER_IMAGE' env var not set" && exit 1
[ "${CI_DOCKER_CONTEXT}" = '' ] && echo "❌ 'CI_DOCKER_CONTEXT' env var not set" && exit 1
[ "${CI_DOCKERFILE}" = '' ] && echo "❌ 'CI_DOCKERFILE' env var not set" && exit 1
[ "${CI_DOCKER_PLATFORM}" = '' ] && echo "❌ 'CI_DOCKER_PLATFORM' env var not set" && exit 1

[ "${DOCKER_PASSWORD}" = '' ] && echo "❌ 'DOCKER_PASSWORD' env var not set" && exit 1
[ "${DOCKER_USER}" = '' ] && echo "❌ 'DOCKER_USER' env var not set" && exit 1

[ "${LATEST_BRANCH}" = '' ] && echo "❌ 'LATEST_BRANCH' env var not set" && exit 1

# Optional semver version (set on release/CD). Empty on per-commit CI.
version="$1"

set -eou pipefail

onExit() {
  rc="$?"
  if [ "$rc" = '0' ]; then
    echo "✅ Successfully built and pushed images"
  else
    echo "❌ Failed to build/push Docker image"
  fi
}

trap onExit EXIT

# Login to registry
echo "🔐 Logging into docker registry..."
echo "${DOCKER_PASSWORD}" | docker login "${DOMAIN}" -u "${DOCKER_USER}" --password-stdin
echo "✅ Successfully logged into docker registry!"

echo "📝 Generating Image tags..."

# Obtain image id
IMAGE_ID="${DOMAIN}/${GITHUB_REPO_REF}/${CI_DOCKER_IMAGE//[._-]*$//}"
IMAGE_ID=$(echo "${IMAGE_ID}" | tr '[:upper:]' '[:lower:]') # convert to lower case

# obtaining the version
SHA="$(echo "${GITHUB_SHA}" | head -c 6)"
BRANCH="${GITHUB_BRANCH//[._-]*$//}"
IMAGE_VERSION="${SHA}-${BRANCH}"

# Generate image references
COMMIT_IMAGE_REF="${IMAGE_ID}:${IMAGE_VERSION}"
BRANCH_IMAGE_REF="${IMAGE_ID}:${BRANCH}"
LATEST_IMAGE_REF="${IMAGE_ID}:latest"
[ "${version}" != '' ] && SEMVER_IMAGE_REF="${IMAGE_ID}:${version}"

echo "  ✅ Commit Image Ref: ${COMMIT_IMAGE_REF}"
echo "  ✅ Branch Image Ref: ${BRANCH_IMAGE_REF}"
echo "  ✅ Latest Image Ref: ${LATEST_IMAGE_REF}"
[ "${version}" != '' ] && echo "  ✅ Semver Image Ref: ${SEMVER_IMAGE_REF}"

echo "🔨 Building Dockerfile..."
args=""
if [ "$BRANCH" = "$LATEST_BRANCH" ]; then
  echo "🔎 Detected branch is '${LATEST_BRANCH}', push 'latest' tag!"
  args="-t ${LATEST_IMAGE_REF}"
fi
if [ "${version}" != '' ]; then
  args="${args} -t ${SEMVER_IMAGE_REF}"
fi

# shellcheck disable=SC2086
docker buildx build \
  "${CI_DOCKER_CONTEXT}" \
  -f "${CI_DOCKERFILE}" \
  --platform=${CI_DOCKER_PLATFORM} \
  --push \
  -t "${COMMIT_IMAGE_REF}" $args \
  -t "${BRANCH_IMAGE_REF}"
echo "✅ Pushed images!"
