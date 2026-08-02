#!/usr/bin/env bash

set -euo pipefail

# Installs the CyanPrint CLI from its immutable GitHub Release Debian asset.
#
# The version and both per-architecture SHA-256 digests are pinned below. This installer
# must never resolve to "latest": the repository's fixtures and `cyanprint test template .`
# invocation are tied to the v2 CLI, so a floating install would silently change what CI
# validates. There is deliberately no fallback path -- any deviation fails closed.
#
# Release: https://github.com/AtomiCloud/sulfone.iridium/releases/tag/v2.20.0

CYANPRINT_VERSION=2.20.0
readonly CYANPRINT_VERSION
readonly CYANPRINT_REPO=AtomiCloud/sulfone.iridium
readonly CYANPRINT_SHA256_AMD64=15a0325c67b7c07edba7cc431f707e0d0fb3e335b47ffee05a6c603c7d0ac36b
readonly CYANPRINT_SHA256_ARM64=f7d3b7fb48f3402166c7313d4de6515cf0840043d9504236006f517bb4deab73

fail() {
  printf 'cyanprint install failed: %s\n' "$*" >&2
  exit 1
}

for tool in curl sha256sum dpkg sudo; do
  command -v "${tool}" >/dev/null 2>&1 || fail "${tool} is required but not on PATH"
done

# Only these two architectures are published for this release. Anything else fails closed
# rather than downloading an asset that does not exist.
arch="$(dpkg --print-architecture)" || fail 'could not determine the host architecture'
case "${arch}" in
  amd64) expected_sha256="${CYANPRINT_SHA256_AMD64}" ;;
  arm64) expected_sha256="${CYANPRINT_SHA256_ARM64}" ;;
  *) fail "unsupported architecture '${arch}': CyanPrint ${CYANPRINT_VERSION} publishes only amd64 and arm64" ;;
esac

package="cyanprint_${CYANPRINT_VERSION}_linux_${arch}.deb"
url="https://github.com/${CYANPRINT_REPO}/releases/download/v${CYANPRINT_VERSION}/${package}"

workdir="$(mktemp -d)"
[[ -n "${workdir}" && -d "${workdir}" ]] || fail 'could not create a temporary working directory'
cleanup() {
  rm -rf -- "${workdir}"
}
trap cleanup EXIT

printf '⬇️  Downloading %s\n' "${url}"
curl_args=(
  --fail
  --location
  --retry 3
  --connect-timeout 20
  --max-time 600
  --silent
  --show-error
)
# --retry-all-errors landed in curl 7.71; probe for it instead of assuming a version.
curl_help="$(curl --help all 2>/dev/null || true)"
if [[ "${curl_help}" == *--retry-all-errors* ]]; then
  curl_args+=(--retry-all-errors)
fi
curl "${curl_args[@]}" --output "${workdir}/${package}" -- "${url}" ||
  fail "could not download ${url}"

printf '🔐 Verifying SHA-256 for %s\n' "${arch}"
printf '%s  %s\n' "${expected_sha256}" "${package}" >"${workdir}/${package}.sha256"
(cd "${workdir}" && sha256sum --check --strict -- "${package}.sha256") ||
  fail "checksum verification failed for ${package}; expected ${expected_sha256}"

printf '📦 Installing %s\n' "${package}"
# The package declares no dependencies, so dpkg alone is sufficient -- no apt involved.
sudo dpkg --install -- "${workdir}/${package}" ||
  fail "dpkg could not install ${package}"

printf '🔎 Verifying the installed CLI\n'
version_output="$(cyanprint --version 2>/dev/null)" ||
  fail 'cyanprint is not runnable after installation'
installed_version="${version_output%%$'\n'*}"
installed_version="${installed_version%$'\r'}"
expected_version="cyanprint ${CYANPRINT_VERSION}"
[[ "${installed_version}" == "${expected_version}" ]] ||
  fail "expected '${expected_version}' but the installed CLI reports '${installed_version}'"

printf '✅ %s\n' "${installed_version}"
