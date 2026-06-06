#!/usr/bin/env bash
set -euo pipefail

# Package and push a Helm chart. With no version it publishes a per-commit prerelease
# (v0.0.0-<sha6>-<branch>); with a version it publishes that release semver. appVersion is set
# on every Chart.yaml so the chart points at the matching image.
#
# Usage: helm.sh <chart_path> [version]

[[ -n "${DOMAIN:-}" ]] || { echo "❌ 'DOMAIN' env var not set"; exit 1; }
[[ -n "${DOCKER_USER:-}" ]] || { echo "❌ 'DOCKER_USER' env var not set"; exit 1; }
[[ -n "${DOCKER_PASSWORD:-}" ]] || { echo "❌ 'DOCKER_PASSWORD' env var not set"; exit 1; }
[[ -n "${GITHUB_SHA:-}" ]] || { echo "❌ 'GITHUB_SHA' env var not set"; exit 1; }
[[ -n "${GITHUB_BRANCH:-}" ]] || { echo "❌ 'GITHUB_BRANCH' env var not set"; exit 1; }
[[ -n "${GITHUB_REPO_REF:-}" ]] || { echo "❌ 'GITHUB_REPO_REF' env var not set"; exit 1; }

chart_path="${1:-}"
version="${2:-}"
[[ -n "${chart_path}" ]] || { echo "❌ chart path (\$1) not set"; exit 1; }

SHA="$(echo "${GITHUB_SHA}" | head -c 6)"
BRANCH="$(echo "${GITHUB_BRANCH}" | sed 's#[/_.]#-#g')"
COMMIT_VERSION="${SHA}-${BRANCH}"

# Substitution picks release vs per-commit version.
HELM_VERSION="${version:-v0.0.0-${COMMIT_VERSION}}"
IMAGE_VERSION="${version:-${COMMIT_VERSION}}"
OCI_REF="$(echo "oci://${DOMAIN}/${GITHUB_REPO_REF}" | tr '[:upper:]' '[:lower:]')"

echo "📝 Helm version ${HELM_VERSION} (appVersion ${IMAGE_VERSION})"
echo "📝 Setting appVersion on charts..."
find . -name 'Chart.yaml' -print0 | while IFS= read -r -d '' file; do
  echo "  📝 ${file}"
  yq eval ".appVersion = \"${IMAGE_VERSION}\"" "${file}" >"${file}.tmp"
  mv "${file}.tmp" "${file}"
done

echo "🔐 Logging into ${DOMAIN}..."
echo "${DOCKER_PASSWORD}" | helm registry login "${DOMAIN}" -u "${DOCKER_USER}" --password-stdin

cd "${chart_path}"
echo "📦 Packaging ${chart_path}..."
helm dependency build
helm package . -u --version "${HELM_VERSION}" --app-version "${IMAGE_VERSION}" -d ./uploads

echo "📤 Pushing chart(s) to ${OCI_REF}..."
for filename in ./uploads/*.tgz; do
  echo "  📤 ${filename}"
  helm push "${filename}" "${OCI_REF}"
done

rm -rf ./uploads
echo "✅ Published helm chart(s)"
