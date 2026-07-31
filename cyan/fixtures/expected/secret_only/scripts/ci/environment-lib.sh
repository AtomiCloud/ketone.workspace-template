#!/usr/bin/env bash
# Shared contract helpers for the runner-local k3d environment lanes.
#
# The ratified Garden ABI in goals/garden-k3d-profiles.md §2 is the only
# lifecycle surface used here:
#
#   pls env switch|up|down|reset|doctor      pls env seed fetch-and-plant
#   pls closure import <bundle>              pls closure preflight --denied-network
#
# Nothing in this tree may invent a second lifecycle. In particular there is no
# `pls env status`, `pls env render`, `pls env artifact`, `pls env closure`,
# `pls env network`, or `pls env vendor-policy`; where a proof needs an
# interface Garden has not ratified yet, the lane refuses with a stable reason
# from the catalogue below rather than fabricating success.
#
# Reason-code catalogue (every refusal exits 64 and prints "<Code>: <detail>"):
#   InputContractInvalid            selector/tuple/manifest shape refused
#   SchemaValidationFailed          a document failed its JSON Schema
#   UntrustedSubject                subject or workflow identity not bound to source_sha
#   DependencyUnavailable           a required command is absent
#   RunnerIsolationUnavailable      runner lease or host posture refused
#   ArtifactProducerUnavailable     no repository-owned immutable artifact subject
#   RuntimeEvidenceUnavailable      Garden emitted no discoverable diene-runtime/v1
#   ReadinessEvidenceUnavailable    `pls env doctor` produced no consumable evidence
#   EnvironmentNotReady             readiness DAG did not converge
#   HostPolicyInterfaceUnavailable  runner host-policy interface absent
#   ProfileRenderInterfaceUnavailable  no ratified runtime-free executable render
#   PreviewIdentityUnavailable      Castform/Eevee executable render is out of node
#   PreviewManifestSchemaMismatch   lock/alias/retired-name drift
#   RequiredCoverageUnavailable     a required fixture/pack/credential is missing
#   JourneyFailed                   a required declared journey failed
#   VendorClassNotAuthorized        class is not the ratified Ditto exception
#   VendorActionFailed              declared vendor adapter failed
#   ReceiptOwnershipMismatch        sweep selector did not match one exact receipt
#   CleanupDebt                     exact cleanup did not converge; debt is visible
#   ReportNamespaceViolation        core/vendor report namespaces crossed
#   EvidenceLeakDetected            leakage canary found in an evidence surface

set -euo pipefail

DIENE_REASON_EXIT=64

diene_die() {
  local code=${1:?reason code required}
  shift
  printf '%s: %s\n' "$code" "$*" >&2
  # Record the stable reason so an EXIT trap can still publish evidence for a
  # failing run instead of leaving the lane red with nothing to read.
  if [[ -n ${DIENE_REASON_FILE:-} ]]; then
    printf '%s\t%s\n' "$code" "$*" >"$DIENE_REASON_FILE" || true
  fi
  exit "$DIENE_REASON_EXIT"
}

diene_warn() {
  local code=${1:?reason code required}
  shift
  printf '%s: %s\n' "$code" "$*" >&2
}

diene_require_command() {
  command -v "$1" >/dev/null 2>&1 || diene_die DependencyUnavailable "$1 is required"
}

diene_require_full_sha() {
  [[ ${2:-} =~ ^[0-9a-f]{40}$ ]] || diene_die InputContractInvalid "$1 must be a full lowercase commit"
}

diene_require_digest() {
  [[ ${2:-} =~ ^sha256:[0-9a-f]{64}$ ]] || diene_die InputContractInvalid "$1 must be sha256:<64 lowercase hex>"
}

diene_require_safe_id() {
  [[ ${2:-} =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || diene_die InputContractInvalid "$1 is not a safe identifier"
}

# ---------------------------------------------------------------------------
# JSON Schema validation. Every document this node reads or emits is validated
# against a real JSON Schema before it is trusted, and always before any `pls`
# invocation. Cross-file $refs resolve from the local schema directory via
# --base-uri so validation stays hermetic; a validator that reached the network
# would break the Absol lane by construction.
# ---------------------------------------------------------------------------

diene_schema_dir() {
  local dir=${DIENE_SCHEMA_DIR:-schemas/ci}
  [[ -d $dir ]] || diene_die InputContractInvalid "schema directory $dir is absent"
  (cd -- "$dir" && pwd)
}

diene_schema_validate() {
  local schema_name=${1:?schema required}
  local document=${2:?document required}
  local label=${3:-$document}
  local validator=${DIENE_SCHEMA_VALIDATOR_BIN:-check-jsonschema}
  diene_require_command "$validator"
  [[ -f $document ]] || diene_die SchemaValidationFailed "$label is absent"
  local dir
  dir=$(diene_schema_dir)
  local schema="$dir/$schema_name"
  [[ -f $schema ]] || diene_die SchemaValidationFailed "schema $schema_name is absent"
  "$validator" --base-uri "file://$dir/" --schemafile "$schema" "$document" >/dev/null ||
    diene_die SchemaValidationFailed "$label does not satisfy $schema_name"
}

# ---------------------------------------------------------------------------
# Lane identity. Every lane derives its own allocation and generation keys, so
# concurrent lanes of one workflow run never share a receipt, a runtime
# directory, or a cleanup selector.
# ---------------------------------------------------------------------------

diene_runtime_profile() {
  case ${1:?lane required} in
    ditto-build-local | ditto-target-pull | ditto-vendor | fleet-independence) printf 'ditto\n' ;;
    absol) printf 'absol\n' ;;
    *) diene_die InputContractInvalid "unknown lane $1" ;;
  esac
}

diene_build_mode() {
  case ${1:?lane required} in
    ditto-target-pull) printf 'target-pull\n' ;;
    ditto-build-local | ditto-vendor | fleet-independence | absol) printf 'build-local\n' ;;
    *) diene_die InputContractInvalid "unknown lane $1" ;;
  esac
}

diene_allocation_key() {
  local lane=${DIENE_LANE:?lane required}
  local key="r${GITHUB_REPOSITORY_ID}-w${GITHUB_RUN_ID}-a${GITHUB_RUN_ATTEMPT}-l${lane}"
  if [[ $lane == ditto-vendor ]]; then
    key="${key}-v${DIENE_ACTION_ID:?action id required}"
  fi
  printf '%s\n' "$key"
}

diene_generation_key() {
  printf 'g%s\n' "${GITHUB_SHA:0:12}"
}

diene_receipt_id() {
  printf '%s-%s\n' "$(diene_allocation_key)" "$(diene_generation_key)"
}

diene_runtime_dir() {
  [[ ${RUNNER_TEMP:-} == /* ]] || diene_die RunnerIsolationUnavailable 'RUNNER_TEMP must be absolute'
  local allocation generation dir
  allocation=$(diene_allocation_key)
  generation=$(diene_generation_key)
  dir="$RUNNER_TEMP/diene/${allocation}-${generation}"
  install -d -m 0700 "$dir"
  printf '%s\n' "$dir"
}

# ---------------------------------------------------------------------------
# Input contract.
# ---------------------------------------------------------------------------

diene_validate_inputs() {
  local lane=${DIENE_LANE:-}
  local repository_id=${GITHUB_REPOSITORY_ID:-}
  local repository_key=${GITHUB_REPOSITORY:-}
  [[ $repository_id =~ ^[1-9][0-9]*$ ]] || diene_die InputContractInvalid 'repository_id must be immutable numeric ID'
  [[ $repository_key =~ ^AtomiCloud/[A-Za-z0-9_.-]+$ ]] || diene_die InputContractInvalid 'repository_key must be canonical AtomiCloud key'
  [[ ${GITHUB_RUN_ID:-} =~ ^[1-9][0-9]*$ && ${GITHUB_RUN_ATTEMPT:-} =~ ^[1-9][0-9]*$ ]] ||
    diene_die InputContractInvalid 'run ID and attempt must be positive integers'
  diene_require_full_sha source_sha "${GITHUB_SHA:-}"
  diene_require_digest garden_lock_digest "${DIENE_GARDEN_LOCK_DIGEST:-}"
  diene_require_digest artifact_digest "${DIENE_ARTIFACT_DIGEST:-}"

  # The base workflow path/ref is part of the trust tuple: a substituted or
  # mutable workflow identity refuses before any credential or substrate touch.
  local workflow_ref=${DIENE_BASE_WORKFLOW_REF:-}
  [[ $workflow_ref =~ ^${repository_key}/\.github/workflows/[^@]+@[0-9a-f]{40}$ ]] ||
    diene_die UntrustedSubject 'base workflow ref must be this repository at a full commit'
  [[ ${workflow_ref##*@} == "${GITHUB_SHA}" ]] ||
    diene_die UntrustedSubject 'base workflow ref does not bind source_sha'

  # The subject is repository-declared, never CI-derived.
  [[ ${DIENE_ARTIFACT_IMAGE_REF:-} =~ @sha256:[0-9a-f]{64}$ ]] ||
    diene_die ArtifactProducerUnavailable 'artifact image ref must be digest-pinned'
  [[ ${DIENE_ARTIFACT_IMAGE_REF##*@} == "${DIENE_ARTIFACT_DIGEST}" ]] ||
    diene_die UntrustedSubject 'artifact image ref and artifact digest disagree'
  [[ ${DIENE_ARTIFACT_PRODUCER_WORKFLOW_REF:-} =~ ^${repository_key}/\.github/workflows/[^@]+@[0-9a-f]{40}$ ]] ||
    diene_die ArtifactProducerUnavailable 'artifact producer workflow ref is absent or not repository-owned'

  case $lane in
    ditto-build-local | ditto-target-pull | absol | fleet-independence)
      [[ ${DIENE_JOURNEY_MANIFEST:-} == .diene/ci/journeys.v1.yaml ]] ||
        diene_die InputContractInvalid 'journey_manifest must be the canonical path'
      [[ -z ${DIENE_VENDOR_MANIFEST:-} && -z ${DIENE_ACTION_ID:-} ]] ||
        diene_die InputContractInvalid 'core lanes forbid vendor selectors'
      ;;
    ditto-vendor)
      [[ -z ${DIENE_JOURNEY_MANIFEST:-} ]] || diene_die InputContractInvalid 'vendor lane forbids journey_manifest'
      [[ ${DIENE_VENDOR_MANIFEST:-} == .diene/ci/vendors.v1.yaml ]] ||
        diene_die InputContractInvalid 'vendor_manifest must be the canonical path'
      [[ ${DIENE_ACTION_ID:-} =~ ^[a-z0-9][a-z0-9-]{0,127}$ ]] ||
        diene_die InputContractInvalid 'action_id is not a safe declared identifier'
      [[ -z ${DIENE_FIXTURE_ID:-} ]] || diene_die InputContractInvalid 'vendor lane forbids fixture selector'
      ;;
    *) diene_die InputContractInvalid "unknown lane $lane" ;;
  esac

  if [[ $lane == ditto-target-pull ]]; then
    diene_require_digest artifact_attestation_digest "${DIENE_ARTIFACT_ATTESTATION_DIGEST:-}"
    [[ -n ${DIENE_ARTIFACT_PULL_IDENTITY:-} ]] ||
      diene_die InputContractInvalid 'target-pull requires a selected-package read identity'
    [[ ${DIENE_ARTIFACT_PULL_IDENTITY} != "${DIENE_ARTIFACT_PRODUCER_WORKFLOW_REF}" ]] ||
      diene_die UntrustedSubject 'puller identity must differ from the publisher'
  else
    [[ -z ${DIENE_ARTIFACT_ATTESTATION_DIGEST:-} && -z ${DIENE_ARTIFACT_PULL_IDENTITY:-} ]] ||
      diene_die InputContractInvalid 'non-pull lane forbids pull selectors'
  fi

  if [[ $lane == absol ]]; then
    diene_require_digest closure_digest "${DIENE_CLOSURE_DIGEST:-}"
    diene_require_digest closure_signature_bundle_digest "${DIENE_CLOSURE_SIGNATURE_BUNDLE_DIGEST:-}"
    diene_require_digest closure_trust_root_digest "${DIENE_CLOSURE_TRUST_ROOT_DIGEST:-}"
    [[ ${DIENE_CLOSURE_BUNDLE_REF:-} =~ ^[A-Za-z][A-Za-z0-9+.-]*://[^[:space:]]+$ && ${DIENE_CLOSURE_BUNDLE_REF} == *"${GITHUB_SHA}"* ]] ||
      diene_die UntrustedSubject 'closure bundle does not bind source_sha'
  else
    [[ -z ${DIENE_CLOSURE_DIGEST:-} && -z ${DIENE_CLOSURE_BUNDLE_REF:-} &&
      -z ${DIENE_CLOSURE_SIGNATURE_BUNDLE_DIGEST:-} && -z ${DIENE_CLOSURE_TRUST_ROOT_DIGEST:-} ]] ||
      diene_die InputContractInvalid 'non-Absol lane forbids closure selectors'
  fi

  if [[ $lane == fleet-independence ]]; then
    [[ ${DIENE_FIXTURE_ID:-} == bootstrap-fleet-independence-v1 ]] ||
      diene_die InputContractInvalid 'independence fixture ID mismatch'
    [[ -z ${DIENE_SEED_IDENTITY:-} ]] || diene_die InputContractInvalid 'independence lane forbids seed identity'
  elif [[ $lane != ditto-vendor ]]; then
    [[ -z ${DIENE_FIXTURE_ID:-} ]] || diene_die InputContractInvalid 'only the independence lane carries a fixture selector'
  fi
}

diene_file_digest() {
  local path=${1:?path required}
  [[ -f $path ]] || diene_die InputContractInvalid "$path is absent"
  printf 'sha256:%s\n' "$(sha256sum -- "$path" | awk '{print $1}')"
}

# ---------------------------------------------------------------------------
# Receipts. The receipt is written BEFORE any substrate mutation so a run that
# is cancelled inside `pls env up` is still swept by owner tuple. It binds the
# Garden-emitted runtime file only once that file has actually been discovered;
# until then it authorises no deletion and can only become visible debt.
# ---------------------------------------------------------------------------

diene_receipt_dir() {
  local dir=${DIENE_RECEIPT_DIR:-${RUNNER_TEMP:?}/diene-receipts}
  install -d -m 0700 "$dir"
  printf '%s\n' "$dir"
}

diene_receipt_path() {
  printf '%s/%s.json\n' "$(diene_receipt_dir)" "${1:?receipt id required}"
}

diene_write_json() {
  local target=${1:?target required}
  local tmp="$target.tmp.$$"
  cat >"$tmp"
  chmod 0600 "$tmp"
  mv -- "$tmp" "$target"
}

diene_arm_receipt() {
  local receipt_id=${1:?receipt id required}
  local lane=${2:?lane required}
  local profile=${3:?profile required}
  local build_mode=${4:?build mode required}
  local policy_mode=${5:-none}
  diene_require_safe_id receipt_id "$receipt_id"
  local receipt
  receipt=$(diene_receipt_path "$receipt_id")
  jq -n \
    --arg repositoryId "$GITHUB_REPOSITORY_ID" \
    --arg repositoryKey "$GITHUB_REPOSITORY" \
    --arg sourceSha "$GITHUB_SHA" \
    --arg runId "$GITHUB_RUN_ID" \
    --arg runAttempt "$GITHUB_RUN_ATTEMPT" \
    --arg receiptId "$receipt_id" \
    --arg allocationKey "$(diene_allocation_key)" \
    --arg generationKey "$(diene_generation_key)" \
    --arg workflowRef "$DIENE_BASE_WORKFLOW_REF" \
    --arg lane "$lane" \
    --arg profile "$profile" \
    --arg buildMode "$build_mode" \
    --arg policyMode "$policy_mode" \
    --arg actionId "${DIENE_ACTION_ID:-}" \
    '{
      apiVersion: "diene.atomi.cloud/ci-receipt/v1",
      owner: {
        repositoryId: $repositoryId, repositoryKey: $repositoryKey, sourceSha: $sourceSha,
        runId: $runId, runAttempt: $runAttempt, receiptId: $receiptId,
        allocationKey: $allocationKey, generationKey: $generationKey, workflowRef: $workflowRef
      },
      lane: $lane, profile: $profile, buildMode: $buildMode,
      runtimeFile: null,
      hostPolicy: { applied: false, mode: $policyMode, allowFile: null },
      cleanup: { outcome: "Pending", reasonCode: "RuntimeArmed", debt: [] }
    }
    + (if $actionId == "" then {} else { actionId: $actionId } end)' |
    diene_write_json "$receipt"
  diene_schema_validate diene-ci-receipt-v1.schema.json "$receipt" 'armed receipt'
  printf '%s\n' "$receipt"
}

diene_receipt_patch() {
  local receipt=${1:?receipt required}
  local filter=${2:?filter required}
  shift 2
  local rendered
  rendered=$(jq "$@" "$filter" "$receipt") || diene_die CleanupDebt 'receipt patch failed'
  printf '%s\n' "$rendered" | diene_write_json "$receipt"
}

# Discover the Garden-emitted diene-runtime/v1 record. Garden owns that file
# (goals/garden-k3d-profiles.md §2); this node only locates and validates it by
# the full immutable owner tuple. Zero or multiple matches refuse rather than
# guessing, and no substitute is ever written.
diene_discover_runtime() {
  local profile=${1:?profile required}
  local allocation_key=${2:?allocation key required}
  local generation_key=${3:?generation key required}
  local search_root=${DIENE_RUNTIME_SEARCH_ROOT:-${RUNNER_TEMP:?}}
  local -a matches=()
  local candidate
  while IFS= read -r -d '' candidate; do
    jq -e \
      --arg repositoryId "$GITHUB_REPOSITORY_ID" \
      --arg repositoryKey "$GITHUB_REPOSITORY" \
      --arg allocationKey "$allocation_key" \
      --arg generationKey "$generation_key" \
      --arg profile "$profile" '
        .apiVersion == "diene-runtime/v1" and .profile == $profile and
        (.owner.repositoryId | tostring) == $repositoryId and
        .owner.repositoryKey == $repositoryKey and
        .owner.allocationKey == $allocationKey and
        .owner.generationKey == $generationKey
      ' "$candidate" >/dev/null 2>&1 && matches+=("$candidate")
  done < <(find "$search_root" -type f -name '*.json' -print0 2>/dev/null)
  ((${#matches[@]} != 0)) || return 1
  ((${#matches[@]} == 1)) || diene_die ReceiptOwnershipMismatch "found ${#matches[@]} runtime records for $allocation_key"
  local runtime=${matches[0]}
  local mode
  mode=$(stat -c %a "$runtime")
  [[ $mode == 600 ]] || diene_die RuntimeEvidenceUnavailable "Garden runtime file mode is $mode, expected 600"
  diene_schema_validate diene-runtime-consumption-v1.schema.json "$runtime" 'Garden runtime record'
  printf '%s\n' "$runtime"
}

# ---------------------------------------------------------------------------
# Host egress policy. The generated allowlist belongs to the runner image
# (AtomiCloud/diene.ci-runners), not to Garden: `pls` ratifies no host-policy
# verb, so inventing `pls env network ...` here would be a second lifecycle.
# When the runner does not expose the interface the lane refuses.
# ---------------------------------------------------------------------------

diene_host_policy_bin() {
  printf '%s\n' "${DIENE_HOST_POLICY_BIN:-/opt/diene/bin/diene-host-policy}"
}

diene_write_allow_file() {
  local target=${1:?target required}
  local mode=${2:?mode required}
  shift 2
  local extra_json='[]'
  if (($#)); then
    extra_json=$(printf '%s\n' "$@" | jq -R . | jq -sc .)
  fi
  jq -n --arg mode "$mode" --argjson extra "$extra_json" \
    '{
      apiVersion: "diene.atomi.cloud/ci-host-policy/v1",
      mode: $mode,
      allow: (["127.0.0.0/8", "::1/128", "10.42.0.0/16", "10.43.0.0/16", "172.16.0.0/12"] + $extra),
      denyDns: true,
      denyDefaultRoute: true
    }' | diene_write_json "$target"
  diene_schema_validate diene-host-policy-v1.schema.json "$target" 'host policy allowlist'
}

diene_host_policy_apply() {
  local receipt_id=${1:?receipt id required}
  local allow_file=${2:?allow file required}
  local bin
  bin=$(diene_host_policy_bin)
  command -v "$bin" >/dev/null 2>&1 || [[ -x $bin ]] ||
    diene_die HostPolicyInterfaceUnavailable "runner host-policy interface $bin is absent; the allowlist cannot be proven"
  "$bin" apply --receipt "$receipt_id" --allow-file "$allow_file" ||
    diene_die HostPolicyInterfaceUnavailable "host policy apply failed for $receipt_id"
}

diene_host_policy_release() {
  local receipt_id=${1:?receipt id required}
  local bin
  bin=$(diene_host_policy_bin)
  "$bin" release --receipt "$receipt_id"
}

# ---------------------------------------------------------------------------
# Declared argv execution. Commands come from schema-validated repository
# declarations, run in a bounded working directory with a bounded timeout, and
# never inherit the caller's stdin.
# ---------------------------------------------------------------------------

diene_run_argv() {
  local manifest=${1:?manifest required}
  local selector=${2:?selector required}
  local phase=${3:?phase required}
  local scratch
  scratch=$(mktemp "${RUNNER_TEMP:-/tmp}/diene-argv.XXXXXX")
  jq -er "$selector | .${phase}[]" "$manifest" >"$scratch" ||
    diene_die InputContractInvalid "$phase argv missing"
  local -a argv=()
  mapfile -t argv <"$scratch"
  rm -f -- "$scratch"
  ((${#argv[@]} > 0)) || diene_die InputContractInvalid "$phase argv empty"
  local working_directory timeout_seconds
  working_directory=$(jq -er "$selector | .workingDirectory" "$manifest") ||
    diene_die InputContractInvalid 'workingDirectory missing'
  timeout_seconds=$(jq -er "$selector | .timeoutSeconds | select(type == \"number\" and . >= 1 and . <= 3600)" "$manifest") ||
    diene_die InputContractInvalid 'bounded timeoutSeconds missing'
  [[ $working_directory =~ ^(\.|[A-Za-z0-9_.-]+)(/[A-Za-z0-9_.-]+)*$ && -d $working_directory ]] ||
    diene_die InputContractInvalid 'workingDirectory escapes or is absent'
  diene_require_command timeout
  (cd -- "$working_directory" && timeout --foreground --kill-after=10s "${timeout_seconds}s" "${argv[@]}" </dev/null)
}

# Bounded, condition-driven wait. Never a retry-to-green loop: it polls one
# condition and reports whether it converged inside its bound.
diene_wait_for() {
  local bound=${1:?bound required}
  local interval=${2:?interval required}
  shift 2
  local waited=0
  while ((waited < bound)); do
    if "$@"; then
      printf '%s\n' "$waited"
      return 0
    fi
    sleep "$interval"
    waited=$((waited + interval))
  done
  printf '%s\n' "$waited"
  return 1
}
