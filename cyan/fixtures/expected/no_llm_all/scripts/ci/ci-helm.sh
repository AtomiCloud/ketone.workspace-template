#!/usr/bin/env bash
set -euo pipefail

# Per-commit CI: package and push every Helm chart, versioned by commit. Loops over all
# Chart.yaml files, so there is no cap on the number of charts published per push.
# Run under Nix: nix develop .#helm -c ./scripts/ci/ci-helm.sh

: "${DOMAIN:?'DOMAIN' env var not set}"
: "${GITHUB_REPO_REF:?'GITHUB_REPO_REF' env var not set}"
: "${GITHUB_SHA:?'GITHUB_SHA' env var not set}"
: "${GITHUB_BRANCH:?'GITHUB_BRANCH' env var not set}"
: "${DOCKER_USER:?'DOCKER_USER' env var not set}"
: "${DOCKER_PASSWORD:?'DOCKER_PASSWORD' env var not set}"

SHA="$(echo "${GITHUB_SHA}" | head -c 6)"
BRANCH="$(echo "${GITHUB_BRANCH}" | sed 's#[/_.]#-#g; s/[^a-zA-Z0-9-]//g')"
IMAGE_VERSION="${SHA}-${BRANCH}"
HELM_VERSION="v0.0.0-${IMAGE_VERSION}"

OCI_REF="$(echo "oci://${DOMAIN}/${GITHUB_REPO_REF}" | tr '[:upper:]' '[:lower:]')"

echo "🔐 Logging into ${DOMAIN}..."
echo "${DOCKER_PASSWORD}" | helm registry login "${DOMAIN}" -u "${DOCKER_USER}" --password-stdin

echo "📝 Helm version: ${HELM_VERSION} (appVersion ${IMAGE_VERSION})"

find . -name 'Chart.yaml' | while read -r chart; do
  dir="$(dirname "${chart}")"
  echo "📦 Packaging ${dir}..."
  yq -i ".appVersion = \"${IMAGE_VERSION}\"" "${chart}"
  (
    cd "${dir}"
    helm dependency build
    helm package . -u --version "${HELM_VERSION}" --app-version "${IMAGE_VERSION}" -d ./uploads
    for tgz in ./uploads/*.tgz; do
      echo "📤 Pushing ${tgz} -> ${OCI_REF}"
      helm push "${tgz}" "${OCI_REF}"
    done
    rm -rf ./uploads
  )
done

echo "✅ Published all Helm charts"
