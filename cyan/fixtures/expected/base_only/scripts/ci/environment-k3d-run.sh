#!/usr/bin/env bash
# Core runtime lane driver: ditto-build-local, ditto-target-pull, absol and
# fleet-independence. Lifecycle is delegated entirely to the ratified Garden
# ABI (goals/garden-k3d-profiles.md §2); this script selects, proves and
# reports, and never reimplements profile selection, k3d creation, receipt
# ownership, readiness or teardown.
set -euo pipefail
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$script_dir/environment-lib.sh"

if [[ ${1:-} == --validate-inputs ]]; then
  diene_validate_inputs
  exit 0
fi

diene_validate_inputs
[[ ${DIENE_LANE} != ditto-vendor ]] || diene_die InputContractInvalid 'vendor lane requires environment-vendor-run.sh'

pls_bin=${DIENE_PLS_BIN:-pls}
diene_require_command jq
diene_require_command sha256sum
diene_require_command timeout
diene_require_command "$pls_bin"
diene_require_command "${DIENE_SCHEMA_VALIDATOR_BIN:-check-jsonschema}"

profile=$(diene_runtime_profile "$DIENE_LANE")
build_mode=$(diene_build_mode "$DIENE_LANE")
allocation_key=$(diene_allocation_key)
generation_key=$(diene_generation_key)
receipt_id=$(diene_receipt_id)
runtime_dir=$(diene_runtime_dir)

export DIENE_REASON_FILE="$runtime_dir/reason"
: >"$DIENE_REASON_FILE"

# Runtime output is routed into mode-0600 staging instead of straight to the
# GitHub log: a canary streamed to the live log is already published and cannot
# be suppressed by a later scan.
export DIENE_EVIDENCE_STAGING="$runtime_dir/evidence"
install -d -m 0700 "$DIENE_EVIDENCE_STAGING"
for surface in stdout stderr argv environ; do
  : >"$DIENE_EVIDENCE_STAGING/$surface"
  chmod 0600 "$DIENE_EVIDENCE_STAGING/$surface"
done
printf '%s\n' "$0" "$@" >"$DIENE_EVIDENCE_STAGING/argv"
# A bounded environment snapshot, so a leak into the process environment is
# detectable. The tracer itself is excluded: it is a marker for other values
# escaping, and matching its own definition would make every run a false hit.
env | grep -v '^DIENE_LEAK_CANARY=' | LC_ALL=C sort >"$DIENE_EVIDENCE_STAGING/environ"
chmod 0600 "$DIENE_EVIDENCE_STAGING/argv" "$DIENE_EVIDENCE_STAGING/environ"

lane_started=$SECONDS
setup_seconds=0
substrate_seconds=0
readiness_seconds=0
journeys_seconds=0
teardown_seconds=0
finalizer_wait=0
substrate_name=""
absence_proof=NotAttempted

# The runner posture is proven before anything else touches the host.
"${DIENE_RUNNER_PREFLIGHT_BIN:-$script_dir/environment-runner-preflight.sh}"

# Every repository declaration is schema-validated before the first `pls` call.
manifest=${DIENE_JOURNEY_MANIFEST}
[[ -f $manifest ]] || diene_die InputContractInvalid 'journey manifest missing'
diene_schema_validate diene-journeys-v1.schema.json "$manifest" 'journey manifest'
jq -e '[.journeys[].id] | length == (unique | length)' "$manifest" >/dev/null ||
  diene_die InputContractInvalid 'journey IDs must be globally stable and unique'
journey_manifest_digest=$(diene_file_digest "$manifest")

environment_lock=${DIENE_ENVIRONMENT_LOCK:-.diene/ci/environment-lock.v1.json}
environment_lock_digest=""
[[ ! -f $environment_lock ]] || environment_lock_digest=$(diene_file_digest "$environment_lock")

results_file="$runtime_dir/journeys.json"
coverage_file="$runtime_dir/coverage.json"
readiness_file="$runtime_dir/readiness.json"
: >"$results_file"
: >"$coverage_file"
: >"$readiness_file"

record_coverage() {
  jq -nc --arg id "$1" --arg reason "$2" \
    '{id: $id, outcome: "Unavailable", reasonCode: $reason, required: false}' >>"$coverage_file"
}

# Garden ratifies no local-finalizer quiescence probe, so the profile's
# finalizer window cannot be observed from here. It is recorded as explicit
# unavailable coverage rather than simulated with an invented flag.
record_coverage local-finalizer-window FinalizerQuiescenceInterfaceUnavailable

# ---------------------------------------------------------------------------
# Host egress posture, the armed receipt, and the traps all precede any
# mutation, so a cancellation inside `pls env up` still converges.
# ---------------------------------------------------------------------------

# `hermetic` denies DNS and every route the isolation receipt does not name;
# `connected` additionally carries the exact seed and registry routes the lane
# genuinely needs. Ditto core is connected by contract, so describing it as
# hermetic would be a posture the lane cannot actually run under.
policy_mode=hermetic
case $DIENE_LANE in
  ditto-build-local | ditto-target-pull) policy_mode=connected ;;
esac

receipt=$(diene_arm_receipt "$receipt_id" "$DIENE_LANE" "$profile" "$build_mode" "$policy_mode")

policy_applied=0
posture_sustained=0
cleanup_attempted=0
cleanup_result=1
teardown_transitions=()
cleanup_debt=()

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

  # Apply-time acknowledgement is not lifetime enforcement: ask the host-owned
  # broker to re-attest that the posture was actually held for the whole lane.
  if ((policy_applied)); then
    if diene_host_policy_verify "$receipt_id"; then
      posture_sustained=1
      teardown_transitions+=("PostureSustained:Pass")
    else
      failed=1
      posture_sustained=0
      teardown_transitions+=("PostureSustained:Fail")
      record_debt "the host-owned egress posture was not sustained for $receipt_id"
    fi
  fi

  # The job may only request deferred cleanup: the outer enforcement persists
  # until root-owned runner teardown removes it, so a job that knows its own
  # receipt cannot dissolve the boundary containing it. Exact removal is the
  # runner lifecycle's evidence to record, not this lane's to claim.
  if ((policy_applied)); then
    if diene_host_policy_request_release "$receipt_id"; then
      teardown_transitions+=("PolicyReleaseRequested:Deferred")
    else
      failed=1
      teardown_transitions+=("PolicyReleaseRequested:Fail")
      record_debt "the deferred host policy cleanup request was not accepted for $receipt_id"
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
  local raw="$runtime_dir/core-report.raw.json"
  local teardown_outcome=Pass
  ((cleanup_result == 0)) || teardown_outcome=Fail
  local transitions debt
  transitions=$(json_array_of "${teardown_transitions[@]}")
  debt=$(json_array_of "${cleanup_debt[@]}")
  [[ -s $readiness_file ]] || printf 'null\n' >"$readiness_file"

  jq -n \
    --arg repositoryRevision "$GITHUB_SHA" \
    --arg runId "$GITHUB_RUN_ID" --arg runAttempt "$GITHUB_RUN_ATTEMPT" \
    --arg workflowRef "$DIENE_BASE_WORKFLOW_REF" \
    --arg lane "$DIENE_LANE" --arg profile "$profile" --arg buildMode "$build_mode" \
    --arg artifactDigest "$DIENE_ARTIFACT_DIGEST" \
    --arg imageRef "${DIENE_SUBJECT_IMAGE_REF:-}" \
    --arg producerWorkflowRef "${DIENE_SUBJECT_PRODUCER_WORKFLOW_REF:-}" \
    --arg attestationDigest "${DIENE_ARTIFACT_ATTESTATION_DIGEST:-}" \
    --arg closureDigest "${DIENE_CLOSURE_DIGEST:-}" \
    --arg closureSignatureDigest "${DIENE_CLOSURE_SIGNATURE_BUNDLE_DIGEST:-}" \
    --arg closureTrustRootDigest "${DIENE_CLOSURE_TRUST_ROOT_DIGEST:-}" \
    --arg allocationKey "$allocation_key" --arg generationKey "$generation_key" \
    --arg substrateName "$substrate_name" \
    --arg receiptId "$receipt_id" \
    --arg gardenLockDigest "$DIENE_GARDEN_LOCK_DIGEST" \
    --arg journeyManifestDigest "$journey_manifest_digest" \
    --arg environmentLockDigest "$environment_lock_digest" \
    --arg policyMode "$policy_mode" \
    --arg teardownOutcome "$teardown_outcome" \
    --arg absenceProof "$absence_proof" \
    --arg verdict "$verdict" --arg reason "$reason" \
    --argjson policyApplied "$policy_applied" \
    --argjson postureSustained "$posture_sustained" \
    --argjson finalizerWait "$finalizer_wait" \
    --argjson setupSeconds "$setup_seconds" \
    --argjson substrateSeconds "$substrate_seconds" \
    --argjson readinessSeconds "$readiness_seconds" \
    --argjson journeysSeconds "$journeys_seconds" \
    --argjson teardownSeconds "$teardown_seconds" \
    --argjson transitions "$transitions" \
    --argjson debt "$debt" \
    --slurpfile readiness "$readiness_file" \
    --slurpfile journeys "$results_file" \
    --slurpfile coverage "$coverage_file" \
    '{
      apiVersion: "diene.atomi.cloud/ci-environment-report/v1",
      repositoryRevision: $repositoryRevision,
      workflow: { runId: $runId, runAttempt: $runAttempt, workflowRef: $workflowRef },
      lane: $lane, profile: $profile, buildMode: $buildMode,
      subject: ({ artifactDigest: $artifactDigest, imageRef: $imageRef, producerWorkflowRef: $producerWorkflowRef }
        + (if $attestationDigest == "" then {} else { provenanceAttestationDigest: $attestationDigest } end)
        + (if $closureDigest == "" then {} else { closureDigest: $closureDigest } end)
        + (if $closureSignatureDigest == "" then {} else { closureSignatureBundleDigest: $closureSignatureDigest } end)
        + (if $closureTrustRootDigest == "" then {} else { closureTrustRootDigest: $closureTrustRootDigest } end)),
      instance: ({ allocationKey: $allocationKey, generationKey: $generationKey }
        + (if $substrateName == "" then {} else { substrateName: $substrateName } end)),
      receiptId: $receiptId,
      tooling: ({ gardenLockDigest: $gardenLockDigest, journeyManifestDigest: $journeyManifestDigest }
        + (if $environmentLockDigest == "" then {} else { environmentLockDigest: $environmentLockDigest } end)),
      readiness: ($readiness[0] // null),
      journeys: $journeys,
      coverage: $coverage,
      evidence: {
        leakageScan: { outcome: "Pass", reasonCode: "ScanPendingFinalisation", encodings: [], scannedPaths: [] },
        egressCanary: {
          outcome: (if $policyApplied != 1 then "Fail"
                    elif $postureSustained == 1 then "Pass" else "Fail" end),
          reasonCode: (if $policyApplied != 1 then "PostureNeverEstablished"
                       elif $postureSustained == 1 then "HostAttestedPostureSustained"
                       else "PostureNotSustainedForLaneLifetime" end),
          mode: $policyMode
        }
      },
      teardown: {
        outcome: $teardownOutcome,
        reasonCode: (if $teardownOutcome == "Pass" then "ExactReceiptDestroyed" else "CleanupDebt" end),
        transitions: (if ($transitions | length) == 0 then ["NotAttempted"] else $transitions end),
        finalizerWaitSeconds: $finalizerWait,
        debt: $debt,
        absenceProof: $absenceProof
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

  local report=${DIENE_CORE_REPORT:-$RUNNER_TEMP/diene-environment-report.v1.json}
  "$script_dir/environment-report.sh" --kind core --input "$raw" --output "$report"
}

finalize() {
  local prior=$1
  local reason_code="" reason_detail=""
  if [[ -s ${DIENE_REASON_FILE} ]]; then
    IFS=$'\t' read -r reason_code reason_detail <"$DIENE_REASON_FILE" || true
  fi
  : "${reason_detail:-}"
  cleanup "$prior" || true

  local verdict=Pass
  local reason=""
  if ((prior != 0)); then
    verdict=Fail
    reason=${reason_code:-LaneFailed}
  elif ((cleanup_result != 0)); then
    verdict=Fail
    reason=CleanupDebt
  fi

  # Evidence is published for red runs too: a failing lane that emits nothing
  # is indistinguishable from a lane that never ran. A lane whose evidence
  # cannot be published — an unscanned report, a positive canary, a schema
  # violation — is never green.
  local emit_rc=0
  emit_report "$verdict" "$reason" || emit_rc=$?
  ((emit_rc == 0)) || diene_warn EvidenceLeakDetected 'evidence could not be published; the lane cannot be green'

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
# Posture, then substrate.
# ---------------------------------------------------------------------------

# Mandatory lane proofs are demanded before anything at all is touched, so a
# lane that cannot prove its required results never reaches the broker, let
# alone the substrate.
if [[ $DIENE_LANE == ditto-target-pull ]]; then
  pull_proof=$(diene_require_pull_proof)
fi
if [[ $DIENE_LANE == absol ]]; then
  closure_verifier=$(diene_require_closure_verifier)
fi
diene_require_host_broker

case $DIENE_LANE in
  absol)
    # Goal order: verify and import the closure, THEN activate denial, THEN
    # re-render and prove exact-set equality under denial, and only then let
    # any volume or cluster exist.
    "$closure_verifier" verify \
      --digest "$DIENE_CLOSURE_DIGEST" \
      --bundle "$DIENE_CLOSURE_BUNDLE_REF" \
      --signature-digest "$DIENE_CLOSURE_SIGNATURE_BUNDLE_DIGEST" \
      --trust-root-digest "$DIENE_CLOSURE_TRUST_ROOT_DIGEST" ||
      diene_die ClosureAttestationInterfaceUnavailable 'signed closure verification did not pass'
    "$pls_bin" closure import "$DIENE_CLOSURE_BUNDLE_REF"

    allow_file="$runtime_dir/host-policy.json"
    diene_write_allow_file "$allow_file" "$receipt_id" hermetic
    diene_host_policy_apply "$receipt_id" "$allow_file"
    policy_applied=1
    "$pls_bin" closure preflight --denied-network

    "$closure_verifier" exact-set --digest "$DIENE_CLOSURE_DIGEST" --network-denied ||
      diene_die ClosureAttestationInterfaceUnavailable 'exact-set equality did not hold under denial'
    ;;
  fleet-independence)
    allow_file="$runtime_dir/host-policy.json"
    diene_write_allow_file "$allow_file" "$receipt_id" hermetic
    diene_host_policy_apply "$receipt_id" "$allow_file"
    policy_applied=1
    ;;
  ditto-build-local | ditto-target-pull)
    # Connected Ditto is not hermetic: it must reach its scoped seed and, for
    # target-pull, the registry. The broker issues that posture or the lane
    # refuses; it never reports readiness through a posture that makes the
    # required operations impossible.
    allow_file="$runtime_dir/host-policy.json"
    diene_write_allow_file "$allow_file" "$receipt_id" connected
    diene_host_policy_apply "$receipt_id" "$allow_file"
    policy_applied=1
    ;;
esac
if ((policy_applied)); then
  # shellcheck disable=SC2016 # $mode and $file are jq variables, bound below
  diene_receipt_patch "$receipt" '.hostPolicy = {applied: true, mode: $mode, allowFile: $file}' \
    --arg mode "$policy_mode" --arg file "${allow_file:-}"
fi

if [[ $DIENE_LANE == ditto-target-pull ]]; then
  # Mandatory, not optional coverage: refuse when no interface can prove them.
  pull_proof=$(diene_require_pull_proof)
fi

setup_seconds=$((SECONDS - lane_started))
substrate_started=$SECONDS
# --artifact is mandatory for build-local and target-pull.
"$pls_bin" env up --profile "$profile" --build-mode "$build_mode" --artifact "$DIENE_ARTIFACT_DIGEST"
substrate_seconds=$((SECONDS - substrate_started))

runtime_file=$(diene_discover_runtime "$profile" "$allocation_key" "$generation_key") ||
  diene_die RuntimeEvidenceUnavailable "Garden emitted no diene-runtime/v1 record for $allocation_key"
jq -e --arg digest "$DIENE_ARTIFACT_DIGEST" '.artifact.digest == $digest' "$runtime_file" >/dev/null ||
  diene_die UntrustedSubject 'Garden runtime record does not carry the declared artifact digest'
substrate_name=$(jq -r '.substrate.name' "$runtime_file")
# shellcheck disable=SC2016 # $path is a jq variable, bound below
diene_receipt_patch "$receipt" '.runtimeFile = $path | .cleanup.reasonCode = "RuntimeBound"' --arg path "$runtime_file"
export DIENE_GARDEN_RUNTIME_FILE=$runtime_file

# ---------------------------------------------------------------------------
# Readiness, consumed from the ratified read-only doctor command and asserted
# leaf by leaf: an empty or truncated emission refuses instead of passing.
# ---------------------------------------------------------------------------

readiness_started=$SECONDS
"$pls_bin" env doctor --profile "$profile" --json >"$readiness_file" ||
  diene_die ReadinessEvidenceUnavailable 'pls env doctor produced no readiness evidence'
diene_schema_validate diene-readiness-v1.schema.json "$readiness_file" 'readiness evidence'
jq -e --arg profile "$profile" '
  .profile == $profile and .outcome == "Pass" and
  ([.readiness[] | select(.required == true) | .outcome] | length > 0 and all(. == "Pass")) and
  (any(.readiness[]; .id == "EnvironmentReady" and .outcome == "Pass")) and
  ([.readiness[] | select(.id == "AllocationReady" or .id == "CastformProdSafetyReady" or .id == "CallbackReady") | .outcome]
     | all(. == "NotRequired"))
' "$readiness_file" >/dev/null || diene_die EnvironmentNotReady 'resource-native readiness DAG did not converge'

case $DIENE_LANE in
  ditto-target-pull)
    jq -e 'any(.readiness[]; .id == "ArtifactPullReady" and .required == true and .outcome == "Pass")' \
      "$readiness_file" >/dev/null ||
      diene_die EnvironmentNotReady 'target-pull did not prove ArtifactPullReady'
    # Each of these is a required result in the lane table, so each is proven
    # or the lane fails. None of them may become optional green coverage.
    for proof in real-pull evict-repull sibling-denial pull-secret-ownership credential-removal; do
      "$pull_proof" "$proof" --digest "$DIENE_ARTIFACT_DIGEST" --receipt "$receipt_id" ||
        diene_die RequiredCoverageUnavailable "target-pull did not prove $proof"
    done
    ;;
  absol)
    jq -e 'any(.readiness[]; .id == "SeedReady" and .outcome == "NotRequired")' "$readiness_file" >/dev/null ||
      diene_die EnvironmentNotReady 'Absol reported a required seed'
    ;;
  fleet-independence)
    jq -e 'any(.readiness[]; .id == "SeedReady" and .outcome == "NotRequired")' "$readiness_file" >/dev/null ||
      diene_die EnvironmentNotReady 'the independence fixture reported a required seed'
    ;;
esac
readiness_seconds=$((SECONDS - readiness_started))

# ---------------------------------------------------------------------------
# Declared journeys. Every selected journey runs and is reported; the lane does
# not stop at the first failure, so the report carries complete coverage.
# ---------------------------------------------------------------------------

journeys_started=$SECONDS
selection="$runtime_dir/selection.json"
fixture=${DIENE_FIXTURE_ID:-}
jq -c \
  --arg lane "$DIENE_LANE" --arg profile "$profile" --arg mode "$build_mode" --arg fixture "$fixture" '
  .journeys[] |
  select(any(.appliesTo[];
    .lane == $lane and .profile == $profile and .buildMode == $mode and
    ((.fixtureId // "") == $fixture)))
' "$manifest" >"$selection"

required_failure=0
entry_file="$runtime_dir/journey.json"
while IFS= read -r entry; do
  printf '%s\n' "$entry" >"$entry_file"
  journey_id=$(jq -er '.id' "$entry_file")
  pack_id=$(jq -er '.fixturePack.id' "$entry_file")
  pack_digest=$(jq -er '.fixturePack.digest' "$entry_file")
  journey_required=$(jq -r '.required' "$entry_file")
  diene_require_safe_id fixture_pack_id "$pack_id"
  pack_path=".diene/ci/fixtures/$pack_id/manifest.yaml"
  journey_started=$SECONDS

  if [[ ! -f $pack_path ]]; then
    # A required missing pack is blocking Fail; an optional one is
    # non-blocking Unavailable and never counts as passed.
    if [[ $journey_required == true ]]; then
      outcome=Fail
      required_failure=1
    else
      outcome=Unavailable
    fi
    jq -nc --arg id "$journey_id" --arg outcome "$outcome" \
      --argjson required "$journey_required" --argjson duration "$((SECONDS - journey_started))" \
      '{id: $id, outcome: $outcome, reasonCode: "FixtureUnavailable", required: $required, durationSeconds: $duration}' \
      >>"$results_file"
    continue
  fi

  # The declared pack digest is immutable: bytes that drift from the
  # declaration are refused rather than silently exercised.
  actual_pack_digest=$(diene_file_digest "$pack_path")
  if [[ $actual_pack_digest != "$pack_digest" ]]; then
    required_failure=1
    jq -nc --arg id "$journey_id" --argjson required "$journey_required" \
      --argjson duration "$((SECONDS - journey_started))" --arg digest "$actual_pack_digest" \
      '{id: $id, outcome: "Fail", reasonCode: "FixturePackDigestMismatch", required: $required, durationSeconds: $duration, fixturePackDigest: $digest}' \
      >>"$results_file"
    continue
  fi

  outcome=Pass
  reason=AssertionsSatisfied
  if ! diene_run_argv "$entry_file" '.' setup; then
    outcome=Fail
    reason=SetupFailed
  elif ! diene_run_argv "$entry_file" '.' probe; then
    outcome=Fail
    reason=ProbeFailed
  fi
  # Cleanup failure is always Fail or visible receipt-scoped debt, regardless
  # of whether the journey itself was required.
  if ! diene_run_argv "$entry_file" '.' cleanup; then
    outcome=Fail
    reason=CleanupFailed
    required_failure=1
  fi
  [[ $outcome == Pass || $journey_required != true ]] || required_failure=1

  jq -nc --arg id "$journey_id" --arg outcome "$outcome" --arg reason "$reason" \
    --argjson required "$journey_required" --argjson duration "$((SECONDS - journey_started))" \
    --arg digest "$pack_digest" \
    '{id: $id, outcome: $outcome, reasonCode: $reason, required: $required, durationSeconds: $duration, fixturePackDigest: $digest}' \
    >>"$results_file"
done <"$selection"
journeys_seconds=$((SECONDS - journeys_started))

if [[ ! -s $results_file ]]; then
  jq -nc '{id: "NoDeclaration", outcome: "NotApplicable", reasonCode: "NoDeclaration", required: false, durationSeconds: 0}' \
    >"$results_file"
fi

((required_failure == 0)) || diene_die JourneyFailed 'a required declared journey did not pass'

printf 'subject_digest=%s\nreceipt_id=%s\nallocation_key=%s\n' \
  "$DIENE_ARTIFACT_DIGEST" "$receipt_id" "$allocation_key" >>"${GITHUB_OUTPUT:-/dev/null}"
