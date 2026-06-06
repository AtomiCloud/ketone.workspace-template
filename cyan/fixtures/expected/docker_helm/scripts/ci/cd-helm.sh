#!/usr/bin/env bash
set -euo pipefail

# CD (release): repackage every Helm chart at the release semver, with appVersion pointing at
# the commit image version already built by CI. Loops over all Chart.yaml files (no cap).
# Run under Nix: nix develop .#helm -c ./scripts/ci/cd-helm.sh <release-version>
#
# Usage: cd-helm.sh <release-version>   (e.g. v1.2.3; falls back to GITHUB_REF_NAME)

: "${DOMAIN:?'DOMAIN' env var not set}"
: "${GITHUB_REPO_REF:?'GITHUB_REPO_REF' env var not set}"
: "${GITHUB_SHA:?'GITHUB_SHA' env var not set}"
: "${DOCKER_USER:?'DOCKER_USER' env var not set}"
: "${DOCKER_PASSWORD:?'DOCKER_PASSWORD' env var not set}"

RELEASE_VERSION="${1:-${GITHUB_REF_NAME:-}}"
: "${RELEASE_VERSION:?'release version ($1 or GITHUB_REF_NAME) not set'}"

# The release tag points at a commit on the release branch; its CI image is <sha6>-<branch>.
LATEST_BRANCH="${LATEST_BRANCH:-main}"
SHA="$(echo "${GITHUB_SHA}" | head -c 6)"
IMAGE_VERSION="${SHA}-${LATEST_BRANCH}"
CHART_VERSION="${RELEASE_VERSION#v}"

OCI_REF="$(echo "oci://${DOMAIN}/${GITHUB_REPO_REF}" | tr '[:upper:]' '[:lower:]')"

echo "🔐 Logging into ${DOMAIN}..."
echo "${DOCKER_PASSWORD}" | helm registry login "${DOMAIN}" -u "${DOCKER_USER}" --password-stdin

echo "📝 Helm version: ${CHART_VERSION} (appVersion ${IMAGE_VERSION})"

find . -name 'Chart.yaml' | while read -r chart; do
  dir="$(dirname "${chart}")"
  echo "📦 Repackaging ${dir} at ${CHART_VERSION}..."
  yq -i ".appVersion = \"${IMAGE_VERSION}\"" "${chart}"
  (
    cd "${dir}"
    helm dependency build
    helm package . -u --version "${CHART_VERSION}" --app-version "${IMAGE_VERSION}" -d ./uploads
    for tgz in ./uploads/*.tgz; do
      echo "📤 Pushing ${tgz} -> ${OCI_REF}"
      helm push "${tgz}" "${OCI_REF}"
    done
    rm -rf ./uploads
  )
done

echo "✅ Republished all Helm charts at ${CHART_VERSION}"
