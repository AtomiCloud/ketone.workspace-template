#!/usr/bin/env bash

set -euo pipefail

# Validates that the Helm module's rendered-manifest validation tools (kubeconform,
# kyverno) are declared exactly once, inherited from the pinned nixpkgs channel, and
# reachable on PATH in the Helm template and in every Helm fixture -- and that they are
# absent from every non-Helm fixture.
#
# The Helm/non-Helm split is DERIVED from test.cyan.yaml rather than maintained as a list
# inside this script, so the gate cannot certify a classification that contradicts the
# tests. Only bash, awk, sed, grep, find and nix-instantiate are used.

# Anchor to the repository root so relative paths behave identically from any cwd.
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

readonly TOOLS=(kubeconform kyverno)
readonly MANIFEST=test.cyan.yaml
readonly FIXTURE_ROOT=cyan/fixtures/expected
readonly HELM_ANSWER=atomi/helm
readonly CHANNEL_BLOCK=nix-2605
readonly CHANNEL_SOURCE=pkgs-2605
readonly LINT_LIST=lint
readonly SOURCE_ENV=templates/helm/nix/env.nix
readonly SOURCE_PACKAGES=templates/helm/nix/packages.nix
readonly SOURCE_SHELLS=templates/helm/nix/shells.nix
# The tools live in the lint group, so every linting shell must compose it. `cd` is the
# deploy shell and deliberately omits lint. `default` is the one shell the Helm template
# module defines on its own; `ci` and `releaser` only appear once the base module is
# merged in, so they are checked when present instead of being required.
readonly REQUIRED_LINT_SHELL=default
readonly OPTIONAL_LINT_SHELLS=(ci releaser)

fail() {
  printf 'helm-tooling validation failed: %s\n' "$*" >&2
  exit 1
}

# --- fixture classification, derived from the test manifest -------------------------

# Emits "<fixture-dir> helm|non-helm" per test case, and exits non-zero on a malformed,
# duplicate or unclassifiable row rather than guessing.
derive_classification() {
  awk -v answer="${HELM_ANSWER}" -v root="${FIXTURE_ROOT}" -v quote="'" '
    function reject(msg) {
      printf "%s\n", msg > "/dev/stderr"
      bad = 1
    }

    function emit() {
      if (name == "") return
      cases++
      if (name in named) {
        reject("duplicate test name: " name)
        return
      }
      named[name] = 1
      if (path == "") {
        reject("test " name " declares no expected snapshot path")
        return
      }
      if (helm == "") {
        reject("test " name " declares no " answer " answer")
        return
      }
      if (helm != "true" && helm != "false") {
        reject("test " name " has a non-boolean " answer " answer: " helm)
        return
      }
      if (index(path, root "/") != 1) {
        reject("test " name " snapshot path is outside " root ": " path)
        return
      }
      fixture = substr(path, length(root) + 2)
      if (fixture == "" || index(fixture, "/") != 0) {
        reject("test " name " snapshot path is not a direct fixture directory: " path)
        return
      }
      if (fixture in claimed) {
        reject("fixture " fixture " is claimed by both " claimed[fixture] " and " name)
        return
      }
      claimed[fixture] = name
      if (helm == "true") print fixture, "helm"
      else print fixture, "non-helm"
    }

    /^  - name:[[:space:]]/ {
      emit()
      name = $0
      sub(/^  - name:[[:space:]]*/, "", name)
      path = ""
      helm = ""
      in_answers = 0
      key = ""
      next
    }
    /^        path:[[:space:]]/ {
      if (path == "") {
        path = $0
        sub(/^        path:[[:space:]]*/, "", path)
      }
      next
    }
    /^    answer_state:[[:space:]]*$/ { in_answers = 1; key = ""; next }
    /^    [^[:space:]]+:/ { in_answers = 0; key = ""; next }
    in_answers && /^      [^[:space:]]+:[[:space:]]*$/ {
      key = $0
      sub(/^      /, "", key)
      sub(/:[[:space:]]*$/, "", key)
      next
    }
    in_answers && key == answer && /^        value:[[:space:]]/ {
      helm = $0
      sub(/^        value:[[:space:]]*/, "", helm)
      gsub(/["]/, "", helm)
      gsub(quote, "", helm)
      next
    }
    END {
      emit()
      if (cases == 0) reject("no test cases found")
      if (bad) exit 1
    }
  ' "${MANIFEST}"
}

# --- nix assertions -----------------------------------------------------------------

# The tool must occupy exactly one line of its own, so a duplicate declaration or a stray
# extra mention is caught before the structural checks run.
require_exactly_once() {
  local file="$1"
  local tool="$2"
  local count

  [[ -f "${file}" ]] || fail "missing ${file}"
  count="$(grep -Ec "^[[:space:]]*${tool}([[:space:]]|$)" "${file}" || true)"
  [[ "${count}" == 1 ]] || fail "expected ${tool} exactly once in ${file}, found ${count}"
}

# Absence is matched anywhere on the line, not just as a leading token, so an inline entry
# such as `lint = [ kyverno` is caught. `#` comments are stripped first so prose may still
# name the tool, and the word boundary keeps `kyverno-cli`/`mykyverno` from tripping it.
require_absent() {
  local file="$1"
  local tool="$2"
  local stripped

  [[ -f "${file}" ]] || fail "missing ${file}"
  stripped="$(sed 's/#.*$//' "${file}")"
  if grep -Eq "(^|[^[:alnum:]_'-])${tool}([^[:alnum:]_'-]|$)" <<<"${stripped}"; then
    fail "unexpected ${tool} in non-Helm fixture ${file}"
  fi
}

# The tool must be a bare element of the named list (`lint = [ ... ];`).
require_in_list() {
  local file="$1"
  local list="$2"
  local tool="$3"
  local status=0

  [[ -f "${file}" ]] || fail "missing ${file}"
  awk -v list="${list}" -v tool="${tool}" '
    BEGIN { code = 2 }
    !inside && $0 ~ "^[[:space:]]*" list "[[:space:]]*=[[:space:]]*\\[" { inside = 1; code = 3; next }
    !inside { next }
    $1 == tool { code = 0; exit }
    $1 == "];" { exit }
    END { exit code }
  ' "${file}" || status=$?

  case "${status}" in
    0) ;;
    2) fail "no ${list} list in ${file}" ;;
    3) fail "expected ${tool} inside the ${list} list in ${file}" ;;
    *) fail "unexpected status ${status} checking ${list}/${tool} in ${file}" ;;
  esac
}

# The tool must be inherited from the pinned channel: the named block has to bind
# `with <source>;`, and the tool has to sit inside that block's `inherit ... ;`
# declaration. An alias such as `kyverno = pkgs.hello;` is rejected.
require_inherited_from_channel() {
  local file="$1"
  local block="$2"
  local source="$3"
  local tool="$4"
  local status=0

  [[ -f "${file}" ]] || fail "missing ${file}"
  awk -v block="${block}" -v source="${source}" -v tool="${tool}" '
    BEGIN { code = 2 }
    !inside && $0 ~ "^[[:space:]]*" block "[[:space:]]*=" { inside = 1; code = 3; next }
    !inside { next }
    !bound && $1 == "with" {
      if ($2 != source ";") exit
      bound = 1
      code = 4
      next
    }
    bound && $0 ~ /^[[:space:]]*inherit[[:space:]]*$/ { in_inherit = 1; next }
    in_inherit && $1 == ";" { in_inherit = 0; next }
    in_inherit && $1 == tool { code = 0; exit }
    $1 == ");" { exit }
    END { exit code }
  ' "${file}" || status=$?

  case "${status}" in
    0) ;;
    2) fail "no ${block} block in ${file}" ;;
    3) fail "${block} in ${file} must bind 'with ${source};'" ;;
    4) fail "expected ${tool} in the inherit declaration of ${block} in ${file}" ;;
    *) fail "unexpected status ${status} checking ${block}/${tool} in ${file}" ;;
  esac
}

# The channel block must be merged into the file's result attrset, otherwise everything
# declared inside it is dead code.
require_merged_package_set() {
  local file="$1"
  local package_set="$2"
  local status=0

  [[ -f "${file}" ]] || fail "missing ${file}"
  awk -v package_set="${package_set}" '
    BEGIN { code = 2 }
    /^[[:space:]]*with[[:space:]]+all;[[:space:]]*$/ { tail = 1; code = 3; next }
    !tail { next }
    {
      line = $0
      sub(/#.*$/, "", line)
      n = split(line, parts, /[^[:alnum:]_-]+/)
      for (i = 1; i <= n; i++) if (parts[i] == package_set) code = 0
    }
    END { exit code }
  ' "${file}" || status=$?

  case "${status}" in
    0) ;;
    2) fail "no 'with all;' result expression in ${file}" ;;
    3) fail "expected ${package_set} in the merged result of ${file}" ;;
    *) fail "unexpected status ${status} checking the merged result of ${file}" ;;
  esac
}

# A linting shell must compose the lint group, or the tools never reach PATH.
require_shell_composes_lint() {
  local file="$1"
  local shell="$2"
  local presence="$3" # required | optional
  local status=0

  [[ -f "${file}" ]] || fail "missing ${file}"
  awk -v shell="${shell}" -v list="${LINT_LIST}" '
    BEGIN { code = 2 }
    !inside && $0 ~ "^[[:space:]]*" shell "[[:space:]]*=[[:space:]]*pkgs\\.mkShell" { inside = 1; code = 3; next }
    !inside { next }
    /buildInputs[[:space:]]*=/ {
      line = $0
      sub(/#.*$/, "", line)
      sub(/.*buildInputs[[:space:]]*=/, "", line)
      n = split(line, parts, /[^[:alnum:]_-]+/)
      for (i = 1; i <= n; i++) if (parts[i] == list) code = 0
      exit
    }
    $1 == "};" { exit }
    END { exit code }
  ' "${file}" || status=$?

  case "${status}" in
    0) ;;
    2)
      if [[ "${presence}" == optional ]]; then
        return 0
      fi
      fail "no ${shell} shell defined in ${file}"
      ;;
    3) fail "the ${shell} shell in ${file} does not compose ${LINT_LIST}; ${TOOLS[*]} would never reach PATH" ;;
    *) fail "unexpected status ${status} checking the ${shell} shell in ${file}" ;;
  esac
}

require_lint_shells() {
  local file="$1"
  local shell

  require_shell_composes_lint "${file}" "${REQUIRED_LINT_SHELL}" required
  for shell in "${OPTIONAL_LINT_SHELLS[@]}"; do
    require_shell_composes_lint "${file}" "${shell}" optional
  done
}

# --- classification -----------------------------------------------------------------

[[ -f "${MANIFEST}" ]] || fail "missing ${MANIFEST}"
[[ -d "${FIXTURE_ROOT}" ]] || fail "missing fixture directory ${FIXTURE_ROOT}"

classification="$(derive_classification)" ||
  fail "could not derive the Helm/non-Helm fixture split from ${MANIFEST}"

declare -A FIXTURE_KIND=()
HELM_FIXTURES=()
NON_HELM_FIXTURES=()

while read -r fixture kind; do
  [[ -n "${fixture}" ]] || continue
  [[ -d "${FIXTURE_ROOT}/${fixture}" ]] ||
    fail "${MANIFEST} classifies ${fixture} but ${FIXTURE_ROOT}/${fixture} does not exist"
  FIXTURE_KIND["${fixture}"]="${kind}"
  case "${kind}" in
    helm) HELM_FIXTURES+=("${fixture}") ;;
    non-helm) NON_HELM_FIXTURES+=("${fixture}") ;;
    *) fail "unknown fixture kind '${kind}' for ${fixture}" ;;
  esac
done <<<"${classification}"

((${#HELM_FIXTURES[@]} > 0)) || fail "no Helm fixtures derived from ${MANIFEST}"
((${#NON_HELM_FIXTURES[@]} > 0)) || fail "no non-Helm fixtures derived from ${MANIFEST}"

# Every fixture directory on disk -- dotted ones included -- must be claimed by a test.
disk_fixtures="$(find "${FIXTURE_ROOT}" -mindepth 1 -maxdepth 1 -type d | LC_ALL=C sort)"
while IFS= read -r fixture_dir; do
  [[ -n "${fixture_dir}" ]] || continue
  fixture="${fixture_dir##*/}"
  [[ -n "${FIXTURE_KIND[${fixture}]:-}" ]] ||
    fail "unclassified fixture directory: ${fixture} (no ${MANIFEST} test claims it)"
done <<<"${disk_fixtures}"

# --- tool assertions ----------------------------------------------------------------

for tool in "${TOOLS[@]}"; do
  require_exactly_once "${SOURCE_ENV}" "${tool}"
  require_exactly_once "${SOURCE_PACKAGES}" "${tool}"
  require_in_list "${SOURCE_ENV}" "${LINT_LIST}" "${tool}"
  require_inherited_from_channel "${SOURCE_PACKAGES}" "${CHANNEL_BLOCK}" "${CHANNEL_SOURCE}" "${tool}"

  for fixture in "${HELM_FIXTURES[@]}"; do
    env_file="${FIXTURE_ROOT}/${fixture}/nix/env.nix"
    packages_file="${FIXTURE_ROOT}/${fixture}/nix/packages.nix"
    require_exactly_once "${env_file}" "${tool}"
    require_exactly_once "${packages_file}" "${tool}"
    require_in_list "${env_file}" "${LINT_LIST}" "${tool}"
    require_inherited_from_channel "${packages_file}" "${CHANNEL_BLOCK}" "${CHANNEL_SOURCE}" "${tool}"
  done

  for fixture in "${NON_HELM_FIXTURES[@]}"; do
    require_absent "${FIXTURE_ROOT}/${fixture}/nix/env.nix" "${tool}"
    require_absent "${FIXTURE_ROOT}/${fixture}/nix/packages.nix" "${tool}"
  done
done

require_merged_package_set "${SOURCE_PACKAGES}" "${CHANNEL_BLOCK}"
require_lint_shells "${SOURCE_SHELLS}"
for fixture in "${HELM_FIXTURES[@]}"; do
  require_merged_package_set "${FIXTURE_ROOT}/${fixture}/nix/packages.nix" "${CHANNEL_BLOCK}"
  require_lint_shells "${FIXTURE_ROOT}/${fixture}/nix/shells.nix"
done

# --- syntax sweep -------------------------------------------------------------------

command -v nix-instantiate >/dev/null 2>&1 || fail 'nix-instantiate is required'
nix_files=("${SOURCE_ENV}" "${SOURCE_PACKAGES}" "${SOURCE_SHELLS}")
for fixture in "${HELM_FIXTURES[@]}" "${NON_HELM_FIXTURES[@]}"; do
  nix_files+=(
    "${FIXTURE_ROOT}/${fixture}/nix/env.nix"
    "${FIXTURE_ROOT}/${fixture}/nix/packages.nix"
    "${FIXTURE_ROOT}/${fixture}/nix/shells.nix"
  )
done
for file in "${nix_files[@]}"; do
  nix-instantiate --parse "${file}" >/dev/null
done

printf 'helm-tooling validation passed (%s Helm / %s non-Helm fixtures derived from %s)\n' \
  "${#HELM_FIXTURES[@]}" "${#NON_HELM_FIXTURES[@]}" "${MANIFEST}"
