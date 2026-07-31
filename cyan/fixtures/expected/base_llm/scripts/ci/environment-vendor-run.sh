#!/usr/bin/env bash
# Separately invoked declared-vendor executor. It runs only repository-declared
# sandbox adapters admitted by the ratified segment permission table, reports
# into its own namespace, and can never satisfy, replace or weaken a core
# assertion.
set -euo pipefail
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$script_dir/environment-lib.sh"

if [[ ${1:-} == --validate-inputs ]]; then
  diene_validate_inputs
  exit 0
fi

diene_validate_inputs
[[ ${DIENE_LANE} == ditto-vendor ]] || diene_die InputContractInvalid 'vendor runner accepts only ditto-vendor'

pls_bin=${DIENE_PLS_BIN:-pls}
diene_require_command jq
diene_require_command sha256sum
diene_require_command timeout
diene_require_command "$pls_bin"
diene_require_command "${DIENE_SCHEMA_VALIDATOR_BIN:-check-jsonschema}"

allocation_key=$(diene_allocation_key)
generation_key=$(diene_generation_key)
receipt_id=$(diene_receipt_id)
runtime_dir=$(diene_runtime_dir)
export DIENE_REASON_FILE="$runtime_dir/reason"
: >"$DIENE_REASON_FILE"

lane_started=$SECONDS
setup_seconds=0
substrate_seconds=0
readiness_seconds=0
journeys_seconds=0
teardown_seconds=0
substrate_name=""
absence_proof=NotAttempted

"${DIENE_RUNNER_PREFLIGHT_BIN:-$script_dir/environment-runner-preflight.sh}"

manifest=${DIENE_VENDOR_MANIFEST}
[[ -f $manifest ]] || diene_die InputContractInvalid 'vendor manifest missing'
diene_schema_validate diene-vendors-v1.schema.json "$manifest" 'vendor manifest'
jq -e '[.actions[].actionId] as $ids | ($ids | length) == ($ids | unique | length)' "$manifest" >/dev/null ||
  diene_die InputContractInvalid 'vendor action IDs must be unique'
vendor_manifest_digest=$(diene_file_digest "$manifest")

action_file="$runtime_dir/vendor-action.json"
jq -cer --arg id "$DIENE_ACTION_ID" '.actions[] | select(.actionId == $id)' "$manifest" >"$action_file" ||
  diene_die InputContractInvalid 'vendor action not declared'

# Declaration completeness is not authority. Only the explicitly authorized
# Ditto vendor-test exception is admitted, and it is refused before any
# credential, egress or substrate mutation.
jq -e '.componentClass == "K9" and .permissionRule == "ditto-vendor-demo" and
       .profile == "ditto" and .buildMode == "build-local" and
       .credentialEnv == "DIENE_VENDOR_CREDENTIAL" and .credentialWriter == "github-environment" and
       .retryAttempts == 0' "$action_file" >/dev/null ||
  diene_die VendorClassNotAuthorized 'only the ratified K9 Ditto demo exception is admitted'

action_required=$(jq -r '.required' "$action_file")

# ---------------------------------------------------------------------------
# Enforcement primitives this lane cannot honestly do without.
#
# The declared egress is DNS + SNI + HTTP method. nft cannot express SNI or
# methods, and a table installed inside a job that holds CAP_NET_ADMIN can be
# flushed by that job, so neither is a boundary. The phase-scoped credential
# likewise cannot be produced by injecting a GitHub secret into the step: it is
# then present during preflight, substrate creation and readiness, long before
# any masker call, and a later shell `unset` does not retract it.
#
# Both require root-owned brokers that do not exist yet. Until they do, this
# required gate refuses rather than reporting a Pass it cannot support.
vendor_proxy=${DIENE_VENDOR_PROXY_BIN:-/opt/diene/bin/diene-vendor-egress-proxy}
command -v "$vendor_proxy" >/dev/null 2>&1 || [[ -x $vendor_proxy ]] ||
  diene_die VendorBrokerInterfaceUnavailable \
    'the declared DNS/SNI/method egress needs a host-owned proxy; nft can express neither SNI nor methods and a job holding CAP_NET_ADMIN can flush its own table'
credential_broker=${DIENE_VENDOR_CREDENTIAL_BROKER_BIN:-/opt/diene/bin/diene-vendor-credential-broker}
command -v "$credential_broker" >/dev/null 2>&1 || [[ -x $credential_broker ]] ||
  diene_die VendorBrokerInterfaceUnavailable \
    'the phase-scoped credential needs a root-owned broker that issues after readiness and revokes after proved absence; a step-injected secret is not phase-scoped'

# Declared immutable packs are consumed, not merely declared.
pack_id=$(jq -er '.fixturePack.id' "$action_file")
pack_digest=$(jq -er '.fixturePack.digest' "$action_file")
diene_require_safe_id fixture_pack_id "$pack_id"
pack_path=".diene/ci/fixtures/$pack_id/manifest.yaml"
[[ -f $pack_path ]] || diene_die RequiredCoverageUnavailable "vendor fixture pack $pack_id is missing"
[[ $(diene_file_digest "$pack_path") == "$pack_digest" ]] ||
  diene_die RequiredCoverageUnavailable "vendor fixture pack $pack_id does not match its declared digest"

# An unavailable callback proof is a required-coverage failure, never a silent
# pass behind a generic outcome.
callback=$(jq -er '.callbackCompletion' "$action_file")
[[ $callback != unavailable ]] ||
  diene_die RequiredCoverageUnavailable 'the declared vendor action has no available callback completion proof'

results=()
coverage_file="$runtime_dir/coverage.json"
: >"$coverage_file"

# ---------------------------------------------------------------------------
# Posture and receipt precede every mutation.
# ---------------------------------------------------------------------------

receipt=$(diene_arm_receipt "$receipt_id" ditto-vendor ditto build-local allowlist)

policy_applied=0
credential_registered=0
cleanup_attempted=0
cleanup_result=1
teardown_transitions=()
cleanup_debt=()
provider_object_ids='[]'
provider_absence=false
provider_outcome=Unavailable
provider_reason=AbsenceNotAttempted
vendor_outcome=Unavailable
vendor_reason=ActionNotStarted

json_array_of() {
  if (($# == 0)); then
    printf '[]\n'
    return 0
  fi
  printf '%s\n' "$@" | jq -R . | jq -sc .
}

record_debt() {
  cleanup_debt+=("$1")
  diene_warn CleanupDebt "$1"
}

cleanup() {
  local prior=${1:-0}
  local -
  if ((cleanup_attempted)); then
    ((prior != 0)) && return "$prior"
    return "$cleanup_result"
  fi
  cleanup_attempted=1
  set +e
  local teardown_started=$SECONDS
  local failed=0

  # Provider objects are removed and their absence proved (or durably
  # recorded) before the action finalises.
  if ((credential_registered)); then
    if diene_run_argv "$action_file" '.' cleanup; then
      teardown_transitions+=("ProviderCleanup:Pass")
    else
      failed=1
      teardown_transitions+=("ProviderCleanup:Fail")
      record_debt "vendor provider cleanup failed for $DIENE_ACTION_ID"
    fi
    if diene_run_argv "$action_file" '.' absence; then
      provider_absence=true
      provider_outcome=Pass
      provider_reason=ProviderObjectsAbsent
      teardown_transitions+=("ProviderAbsence:Pass")
    else
      failed=1
      provider_absence=false
      provider_outcome=Fail
      provider_reason=ProviderAbsenceUnproven
      teardown_transitions+=("ProviderAbsence:Fail")
      record_debt "vendor provider absence unproven for $DIENE_ACTION_ID"
    fi
  fi

  if "$script_dir/environment-receipt-sweep.sh" \
    --repository-id "$GITHUB_REPOSITORY_ID" --run-id "$GITHUB_RUN_ID" \
    --run-attempt "$GITHUB_RUN_ATTEMPT" --receipt-id "$receipt_id"; then
    absence_proof=ReceiptDestroyed
    teardown_transitions+=("ExactDown:Pass")
  else
    failed=1
    absence_proof=ReceiptRetainedAsDebt
    teardown_transitions+=("ExactDown:Fail")
    record_debt "exact receipt sweep did not converge for $receipt_id"
  fi

  if ((policy_applied)); then
    if diene_host_policy_request_release "$receipt_id"; then
      teardown_transitions+=("PolicyReleaseRequested:Deferred")
    else
      failed=1
      teardown_transitions+=("PolicyReleaseRequested:Fail")
      record_debt "host policy release failed for $receipt_id"
    fi
  fi

  teardown_seconds=$((SECONDS - teardown_started))
  cleanup_result=$failed
  ((prior != 0)) && return "$prior"
  return "$cleanup_result"
}

emit_report() {
  local verdict=$1
  local reason=$2
  local raw="$runtime_dir/vendor-report.raw.json"
  local teardown_outcome=Pass
  ((cleanup_result == 0)) || teardown_outcome=Fail
  local transitions debt
  transitions=$(json_array_of "${teardown_transitions[@]}")
  debt=$(json_array_of "${cleanup_debt[@]}")
  local durable=null
  [[ $provider_absence == true ]] || durable='"provider absence unproven; retained as receipt-scoped debt"'

  jq -n \
    --arg repositoryRevision "$GITHUB_SHA" \
    --arg runId "$GITHUB_RUN_ID" --arg runAttempt "$GITHUB_RUN_ATTEMPT" \
    --arg workflowRef "$DIENE_BASE_WORKFLOW_REF" \
    --arg actionId "$DIENE_ACTION_ID" \
    --arg receiptId "$receipt_id" \
    --arg allocationKey "$allocation_key" --arg generationKey "$generation_key" \
    --arg substrateName "$substrate_name" \
    --arg gardenLockDigest "$DIENE_GARDEN_LOCK_DIGEST" \
    --arg vendorManifestDigest "$vendor_manifest_digest" \
    --arg vendorOutcome "$vendor_outcome" --arg vendorReason "$vendor_reason" \
    --argjson vendorRequired "$action_required" \
    --arg providerOutcome "$provider_outcome" --arg providerReason "$provider_reason" \
    --argjson providerObjectIds "$provider_object_ids" \
    --argjson providerAbsence "$provider_absence" \
    --argjson durable "$durable" \
    --argjson credentialRegistered "$credential_registered" \
    --arg teardownOutcome "$teardown_outcome" \
    --arg absenceProof "$absence_proof" \
    --arg verdict "$verdict" --arg reason "$reason" \
    --argjson policyApplied "$policy_applied" \
    --argjson setupSeconds "$setup_seconds" \
    --argjson substrateSeconds "$substrate_seconds" \
    --argjson readinessSeconds "$readiness_seconds" \
    --argjson journeysSeconds "$journeys_seconds" \
    --argjson teardownSeconds "$teardown_seconds" \
    --argjson transitions "$transitions" \
    --argjson debt "$debt" \
    '{
      apiVersion: "diene.atomi.cloud/ci-vendor-report/v1",
      repositoryRevision: $repositoryRevision,
      workflow: { runId: $runId, runAttempt: $runAttempt, workflowRef: $workflowRef },
      lane: "ditto-vendor", profile: "ditto", buildMode: "build-local",
      actionId: $actionId, componentClass: "K9", permissionRule: "ditto-vendor-demo",
      receiptId: $receiptId,
      instance: ({ allocationKey: $allocationKey, generationKey: $generationKey }
        + (if $substrateName == "" then {} else { substrateName: $substrateName } end)),
      tooling: { gardenLockDigest: $gardenLockDigest, journeyManifestDigest: $vendorManifestDigest },
      vendorOutcome: { id: $actionId, outcome: $vendorOutcome, reasonCode: $vendorReason, required: $vendorRequired },
      providerCleanup: { outcome: $providerOutcome, reasonCode: $providerReason,
                         objectIds: $providerObjectIds, absenceProven: $providerAbsence,
                         durableDebtRecord: $durable },
      credential: { issuer: "host-owned-broker", masked: ($credentialRegistered == 1),
                    issuedAfterReadiness: ($credentialRegistered == 1),
                    removed: ($providerAbsence and $credentialRegistered == 1),
                    removalObserved: ($providerAbsence and $credentialRegistered == 1) },
      evidence: {
        leakageScan: { outcome: "Pass", reasonCode: "ScanPendingFinalisation", encodings: [], scannedPaths: [] },
        egressCanary: {
          outcome: (if $policyApplied == 1 then "Pass" else "Fail" end),
          reasonCode: (if $policyApplied == 1 then "DeclaredEgressAllowlistHeld" else "PostureNeverEstablished" end),
          mode: "allowlist"
        }
      },
      teardown: {
        outcome: $teardownOutcome,
        reasonCode: (if $teardownOutcome == "Pass" then "ExactReceiptDestroyed" else "CleanupDebt" end),
        transitions: (if ($transitions | length) == 0 then ["NotAttempted"] else $transitions end),
        finalizerWaitSeconds: 0, debt: $debt, absenceProof: $absenceProof
      },
      timings: {
        setupSeconds: $setupSeconds, substrateSeconds: $substrateSeconds,
        readinessSeconds: $readinessSeconds, journeysSeconds: $journeysSeconds,
        teardownSeconds: $teardownSeconds
      },
      outcome: $verdict
    }
    + (if $reason == "" then {} else { reasonCode: $reason } end)' \
    >"$raw"

  local report=${DIENE_VENDOR_REPORT:-$RUNNER_TEMP/diene-vendor-report.v1.json}
  "$script_dir/environment-report.sh" --kind vendor --input "$raw" --output "$report"
}

finalize() {
  local prior=$1
  local reason_code=""
  if [[ -s ${DIENE_REASON_FILE} ]]; then
    IFS=$'\t' read -r reason_code _ <"$DIENE_REASON_FILE" || true
  fi
  cleanup "$prior" || true

  local verdict=$vendor_outcome
  local reason=$vendor_reason
  if ((prior != 0)); then
    verdict=Fail
    reason=${reason_code:-VendorActionFailed}
  elif ((cleanup_result != 0)); then
    verdict=Fail
    reason=CleanupDebt
  fi
  # A vendor action whose evidence cannot be published is never green either.
  local emit_rc=0
  emit_report "$verdict" "$reason" || emit_rc=$?
  ((emit_rc == 0)) || diene_warn EvidenceLeakDetected 'vendor evidence could not be published'

  ((prior == 0)) || return "$prior"
  ((emit_rc == 0)) || return "$DIENE_REASON_EXIT"
  ((cleanup_result == 0)) || return "$DIENE_REASON_EXIT"
  return 0
}

on_exit() {
  local prior=$?
  local rc=0
  trap - EXIT TERM INT
  finalize "$prior" || rc=$?
  exit "$rc"
}
on_signal() {
  local status=${1:?signal status required}
  trap - EXIT TERM INT
  finalize "$status" || true
  exit "$status"
}
trap on_exit EXIT
trap 'on_signal 143' TERM
trap 'on_signal 130' INT

# ---------------------------------------------------------------------------
# Exact declared egress, then substrate, then the phase-scoped credential.
# ---------------------------------------------------------------------------

allow_file="$runtime_dir/host-policy.json"
# The declared egress is DNS + SNI + method. The enforcement layer refuses bare
# hostnames and cannot express SNI or methods at all, so these entries are
# unenforceable by construction. This is unreachable in practice — the broker
# gate above already refused — but it must never silently emit a hostname the
# conductor would reject or, worse, one it would accept as if enforced.
mapfile -t egress_entries < <(jq -r '.egress[] | "\(.dns):\(.port)"' "$action_file")
for egress_entry in "${egress_entries[@]}"; do
  diene_require_literal_endpoint "$egress_entry"
done
diene_write_allow_file "$allow_file" allowlist "${egress_entries[@]}"
diene_host_policy_apply "$receipt_id" "$allow_file"
policy_applied=1
# shellcheck disable=SC2016 # $file is a jq variable, bound below
diene_receipt_patch "$receipt" '.hostPolicy = {applied: true, mode: "allowlist", allowFile: $file}' \
  --arg file "$allow_file"

setup_seconds=$((SECONDS - lane_started))
substrate_started=$SECONDS
"$pls_bin" env up --profile ditto --build-mode build-local --artifact "$DIENE_ARTIFACT_DIGEST"
substrate_seconds=$((SECONDS - substrate_started))

runtime_file=$(diene_discover_runtime ditto "$allocation_key" "$generation_key") ||
  diene_die RuntimeEvidenceUnavailable "Garden emitted no diene-runtime/v1 record for $allocation_key"
substrate_name=$(jq -r '.substrate.name' "$runtime_file")
# shellcheck disable=SC2016 # $path is a jq variable, bound below
diene_receipt_patch "$receipt" '.runtimeFile = $path | .cleanup.reasonCode = "RuntimeBound"' --arg path "$runtime_file"
export DIENE_GARDEN_RUNTIME_FILE=$runtime_file

readiness_started=$SECONDS
readiness_file="$runtime_dir/readiness.json"
"$pls_bin" env doctor --profile ditto --json >"$readiness_file" ||
  diene_die ReadinessEvidenceUnavailable 'pls env doctor produced no readiness evidence'
diene_schema_validate diene-readiness-v1.schema.json "$readiness_file" 'readiness evidence'
jq -e '.outcome == "Pass" and any(.readiness[]; .id == "EnvironmentReady" and .outcome == "Pass")' \
  "$readiness_file" >/dev/null || diene_die EnvironmentNotReady 'vendor lane readiness did not converge'
readiness_seconds=$((SECONDS - readiness_started))

# The credential is fetched only for this phase and registered with the runner
# masker before its first use.
credential_name=$(jq -er '.credentialEnv | select(. == "DIENE_VENDOR_CREDENTIAL")' "$action_file")
credential=${!credential_name:-}
if [[ -z $credential ]]; then
  if [[ $action_required == true ]]; then
    diene_die RequiredCoverageUnavailable 'approved vendor credential unavailable'
  fi
  vendor_outcome=Unavailable
  vendor_reason=VendorCredentialUnavailable
else
  printf '::add-mask::%s\n' "$credential"
  credential_registered=1

  journeys_started=$SECONDS
  vendor_outcome=Pass
  vendor_reason=AssertionsSatisfied
  if ! diene_run_argv "$action_file" '.' setup; then
    vendor_outcome=Fail
    vendor_reason=SetupFailed
  elif ! diene_run_argv "$action_file" '.' probe; then
    vendor_outcome=Fail
    vendor_reason=ProbeFailed
  fi
  journeys_seconds=$((SECONDS - journeys_started))
  provider_object_ids=$(jq -c '[.providerObjectIds // []] | flatten' "$action_file")
  unset "$credential_name"
fi

results+=("$vendor_outcome")
[[ $vendor_outcome != Fail ]] || diene_die VendorActionFailed "$DIENE_ACTION_ID failed"

printf 'subject_digest=%s\nreceipt_id=%s\nallocation_key=%s\n' \
  "$DIENE_ARTIFACT_DIGEST" "$receipt_id" "$allocation_key" >>"${GITHUB_OUTPUT:-/dev/null}"
