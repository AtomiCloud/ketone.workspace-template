#!/usr/bin/env bash

set -euo pipefail

readonly TOOLS=(kubeconform kyverno)
readonly SOURCE_FILES=(
  templates/helm/nix/env.nix
  templates/helm/nix/packages.nix
)
readonly HELM_FIXTURES=(
  all_features
  docker_helm
  helm_only
  no_llm_all
)
readonly NON_HELM_FIXTURES=(
  base_llm
  base_only
  docker_only
  no_llm_docker
  secret_only
)

declare -A FIXTURE_KIND=()

fail() {
  printf 'helm-tooling validation failed: %s\n' "$*" >&2
  exit 1
}

require_exactly_once() {
  local file="$1"
  local tool="$2"
  local count

  [[ -f "${file}" ]] || fail "missing ${file}"
  count="$(grep -Ec "^[[:space:]]*${tool}([[:space:]]|$)" "${file}" || true)"
  [[ "${count}" == 1 ]] || fail "expected ${tool} exactly once in ${file}, found ${count}"
}

require_absent() {
  local file="$1"
  local tool="$2"

  [[ -f "${file}" ]] || fail "missing ${file}"
  if grep -Eq "^[[:space:]]*${tool}([[:space:]]|$)" "${file}"; then
    fail "unexpected ${tool} in non-Helm fixture ${file}"
  fi
}

for fixture in "${HELM_FIXTURES[@]}"; do
  [[ -z "${FIXTURE_KIND[${fixture}]:-}" ]] || fail "duplicate fixture classification: ${fixture}"
  FIXTURE_KIND["${fixture}"]=helm
done
for fixture in "${NON_HELM_FIXTURES[@]}"; do
  [[ -z "${FIXTURE_KIND[${fixture}]:-}" ]] || fail "duplicate fixture classification: ${fixture}"
  FIXTURE_KIND["${fixture}"]=non-helm
done
while IFS= read -r -d '' fixture_dir; do
  fixture="${fixture_dir##*/}"
  [[ -n "${FIXTURE_KIND[${fixture}]:-}" ]] || fail "unclassified fixture directory: ${fixture}"
done < <(find cyan/fixtures/expected -mindepth 1 -maxdepth 1 -type d -print0)

require_in_block() {
  local file="$1"
  local block="$2"
  local closing="$3"
  local tool="$4"

  awk -v block="${block}" -v closing="${closing}" -v tool="${tool}" '
    $0 ~ "^[[:space:]]*" block "[[:space:]]*=" { inside = 1; next }
    inside && $1 == tool { found = 1 }
    inside && $1 == closing { exit(found ? 0 : 1) }
    END { if (!inside || !found) exit 1 }
  ' "${file}" || fail "expected ${tool} inside ${block} in ${file}"
}

require_merged_package_set() {
  local file="$1"
  local package_set="$2"

  awk -v package_set="${package_set}" '
    /^[[:space:]]*with[[:space:]]+all;[[:space:]]*$/ { result = 1; next }
    result && index($0, package_set) { found = 1 }
    END { exit(found ? 0 : 1) }
  ' "${file}" || fail "expected ${package_set} in the merged result of ${file}"
}

for tool in "${TOOLS[@]}"; do
  require_exactly_once "${SOURCE_FILES[0]}" "${tool}"
  require_exactly_once "${SOURCE_FILES[1]}" "${tool}"
  require_in_block "${SOURCE_FILES[0]}" lint '];' "${tool}"
  require_in_block "${SOURCE_FILES[1]}" nix-2605 ');' "${tool}"

  for fixture in "${HELM_FIXTURES[@]}"; do
    env_file="cyan/fixtures/expected/${fixture}/nix/env.nix"
    packages_file="cyan/fixtures/expected/${fixture}/nix/packages.nix"
    require_exactly_once "${env_file}" "${tool}"
    require_exactly_once "${packages_file}" "${tool}"
    require_in_block "${env_file}" lint '];' "${tool}"
    require_in_block "${packages_file}" nix-2605 ');' "${tool}"
  done

  for fixture in "${NON_HELM_FIXTURES[@]}"; do
    require_absent "cyan/fixtures/expected/${fixture}/nix/env.nix" "${tool}"
    require_absent "cyan/fixtures/expected/${fixture}/nix/packages.nix" "${tool}"
  done
done

require_merged_package_set templates/helm/nix/packages.nix nix-2605
for fixture in "${HELM_FIXTURES[@]}"; do
  require_merged_package_set "cyan/fixtures/expected/${fixture}/nix/packages.nix" nix-2605
done

command -v nix-instantiate >/dev/null 2>&1 || fail 'nix-instantiate is required'
nix_files=("${SOURCE_FILES[@]}")
for fixture in "${HELM_FIXTURES[@]}" "${NON_HELM_FIXTURES[@]}"; do
  nix_files+=(
    "cyan/fixtures/expected/${fixture}/nix/env.nix"
    "cyan/fixtures/expected/${fixture}/nix/packages.nix"
  )
done
for file in "${nix_files[@]}"; do
  nix-instantiate --parse "${file}" >/dev/null
done

printf 'helm-tooling validation passed\n'
