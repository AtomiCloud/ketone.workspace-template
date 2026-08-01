#!/usr/bin/env bash
# Credential-free on-instance executor for one explicitly selected Ditto
# vendor action. Namespace lifecycle stays in environment-k3d-run.sh
# orchestrate mode. Credential bytes are issued only after EnvironmentReady by
# an approved guest phase broker, never uploaded by the orchestrator.
set -euo pipefail
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$script_dir/environment-lib.sh"

if [[ ${1:-} == --validate-inputs ]]; then
  diene_validate_inputs
  exit 0
fi
[[ ${1:-} == driver ]] || diene_die InputContractInvalid 'vendor executor accepts only driver mode'
shift
state=${1:?fixed driver state directory required}
diene_load_remote_inputs "$state"
diene_validate_inputs
[[ $DIENE_LANE == ditto-vendor ]] || diene_die InputContractInvalid 'vendor driver accepts only ditto-vendor'

for command in jq sha256sum timeout tar; do diene_require_command "$command"; done
pls_bin=${DIENE_PLS_BIN:-pls}
diene_require_command "$pls_bin"
diene_require_command "${DIENE_SCHEMA_VALIDATOR_BIN:-check-jsonschema}"

evidence="$state/evidence"
install -d -m 0700 "$evidence"
export DIENE_EVIDENCE_STAGING="$evidence/staging"
install -d -m 0700 "$DIENE_EVIDENCE_STAGING"
for surface in stdout stderr argv environ; do
  : >"$DIENE_EVIDENCE_STAGING/$surface"
  chmod 0600 "$DIENE_EVIDENCE_STAGING/$surface"
done
printf '%q ' "$0" "$@" >"$DIENE_EVIDENCE_STAGING/argv"
printf '\n' >>"$DIENE_EVIDENCE_STAGING/argv"
env | grep -v '^DIENE_LEAK_CANARY=' | LC_ALL=C sort >"$DIENE_EVIDENCE_STAGING/environ"
export DIENE_REASON_FILE="$evidence/reason"
: >"$DIENE_REASON_FILE"

receipt="$state/receipts/exact.json"
export DIENE_RECEIPT_DIR="$state/receipts"
diene_validate_receipt_owner "$receipt" "$DIENE_NSC_CLUSTER_ID"
manifest=$DIENE_VENDOR_MANIFEST
[[ -f $manifest ]] || diene_die InputContractInvalid 'vendor manifest missing'
diene_schema_validate diene-vendors-v1.schema.json "$manifest" 'vendor manifest'
jq -e '[.actions[].actionId] | length == (unique | length)' "$manifest" >/dev/null ||
  diene_die InputContractInvalid 'vendor action IDs must be unique'
action="$evidence/vendor-action.json"
jq -cer --arg id "$DIENE_ACTION_ID" '.actions[] | select(.actionId == $id)' "$manifest" >"$action" ||
  diene_die InputContractInvalid 'vendor action is not declared exactly once'
jq -e '
  .componentClass == "K9" and .permissionRule == "ditto-vendor-demo" and
  .profile == "ditto" and .buildMode == "build-local" and
  .credentialEnv == "DIENE_VENDOR_CREDENTIAL" and .credentialWriter == "github-environment" and
  .retryAttempts == 0
' "$action" >/dev/null ||
  diene_die VendorClassNotAuthorized 'only the ratified K9 Ditto demo action is admitted'

pack_id=$(jq -er '.fixturePack.id' "$action")
pack_digest=$(jq -er '.fixturePack.digest' "$action")
pack_path=".diene/ci/fixtures/$pack_id/manifest.yaml"
[[ -f $pack_path && $(diene_file_digest "$pack_path") == "$pack_digest" ]] ||
  diene_die RequiredCoverageUnavailable "vendor fixture $pack_id is absent or changed"
[[ $(jq -r '.callbackCompletion' "$action") != unavailable ]] ||
  diene_die RequiredCoverageUnavailable 'vendor callback completion is unavailable'

broker=${DIENE_VENDOR_CREDENTIAL_BROKER_BIN:-}
[[ -n $broker ]] || diene_die VendorBrokerInterfaceUnavailable 'approved vendor phase broker is absent'
diene_require_command "$broker"

checkpoint="$evidence/checkpoint-chain.json"
input_digest=$(diene_sha256_text \
  "$GITHUB_SHA|$DIENE_SOURCE_ARCHIVE_DIGEST|$DIENE_GARDEN_LOCK_DIGEST|$DIENE_ARTIFACT_DIGEST|$(diene_file_digest "$manifest")|$DIENE_ACTION_ID")
diene_checkpoint_init "$checkpoint" "$input_digest"

runtime_file=
substrate_name=
policy_applied=0
credential_issued=0
cleanup_done=0
cleanup_rc=0
finalized=0
setup_seconds=0
substrate_seconds=0
readiness_seconds=0
action_seconds=0
teardown_seconds=0
provider_absence=false
provider_outcome=Unavailable
provider_reason=AbsenceNotAttempted
provider_ids='[]'
vendor_outcome=Unavailable
vendor_reason=ActionNotStarted
action_required=$(jq -r '.required' "$action")
credential_file="$state/vendor-credential"
credential_evidence="$evidence/credential.json"
object_ids_file="$state/provider-object-ids.json"
printf '[]\n' | diene_write_json "$object_ids_file"
export DIENE_VENDOR_OBJECT_IDS_FILE=$object_ids_file

vendor_cleanup() {
  ((cleanup_done == 0)) || return "$cleanup_rc"
  cleanup_done=1
  local started=$SECONDS failed=0
  if ((credential_issued)); then
    if diene_run_argv "$action" . cleanup; then
      if diene_run_argv "$action" . absence; then
        provider_absence=true
        provider_outcome=Pass
        provider_reason=ProviderObjectsAbsent
      else
        failed=1
        provider_outcome=Fail
        provider_reason=ProviderAbsenceUnproven
      fi
    else
      failed=1
      provider_outcome=Fail
      provider_reason=ProviderCleanupFailed
    fi
    if ! "$broker" revoke --action "$DIENE_ACTION_ID" --credential-file "$credential_file" \
      --absence-proven "$provider_absence"; then
      failed=1
      provider_outcome=Fail
      provider_reason=CredentialRevocationFailed
    fi
    unset DIENE_VENDOR_CREDENTIAL
    if [[ -e $credential_file ]]; then
      # Emptying the phase file before unlinking prevents a readable stale
      # secret if unlink is interrupted; neither file is ever packaged.
      : >"$credential_file"
      chmod 0600 "$credential_file"
      rm -f -- "$credential_file"
    fi
  fi
  if [[ -n $runtime_file ]]; then
    "$script_dir/environment-receipt-sweep.sh" --repository-id "$GITHUB_REPOSITORY_ID" \
      --run-id "$GITHUB_RUN_ID" --run-attempt "$GITHUB_RUN_ATTEMPT" \
      --receipt-id "$(diene_receipt_id)" || failed=1
  else
    diene_receipt_patch "$receipt" '.cleanup = {outcome:"Pass",reasonCode:"NoGardenRuntimeCreated",debt:[]}'
  fi
  if ((policy_applied)); then diene_remove_interim_policy || failed=1; fi
  teardown_seconds=$((SECONDS - started))
  cleanup_rc=$failed
  return "$failed"
}

vendor_emit_report() {
  local verdict=${1:?verdict required} reason=${2:-}
  local preflight="$evidence/preflight.json" probes="$evidence/hostile-probes.json"
  local teardown_outcome=Pass absence=ReceiptDestroyed debt='[]'
  ((cleanup_rc == 0)) || {
    teardown_outcome=Fail
    absence=ReceiptRetainedAsDebt
    debt='["vendor, Garden, credential, or policy cleanup did not converge"]'
  }
  local durable=null
  [[ $provider_absence == true ]] || durable=$(jq -cn --arg id "$(diene_receipt_id)" '$id')
  provider_ids=$(jq -cer 'select(type == "array")' "$object_ids_file" 2>/dev/null || printf '[]')
  jq -n \
    --arg revision "$GITHUB_SHA" --arg runId "$GITHUB_RUN_ID" --arg runAttempt "$GITHUB_RUN_ATTEMPT" \
    --arg workflowRef "$DIENE_BASE_WORKFLOW_REF" --arg actionId "$DIENE_ACTION_ID" \
    --arg component "$(jq -r '.componentClass' "$action")" --arg permission "$(jq -r '.permissionRule' "$action")" \
    --arg receiptId "$(diene_receipt_id)" --arg allocationKey "$(diene_allocation_key)" \
    --arg generationKey "$(diene_generation_key)" --arg substrateName "$substrate_name" \
    --arg clusterId "$DIENE_NSC_CLUSTER_ID" --arg garden "$DIENE_GARDEN_LOCK_DIGEST" \
    --arg vendorDigest "$(diene_file_digest "$manifest")" --arg nscVersion "$DIENE_NSC_VERSION" \
    --arg nscArtifactDigest "$DIENE_NSC_ARTIFACT_DIGEST" \
    --arg nscBinaryDigest "$DIENE_NSC_BINARY_DIGEST" \
    --arg sourceDigest "$DIENE_SOURCE_ARCHIVE_DIGEST" \
    --arg subjectDigest "$(diene_file_digest "$DIENE_ARTIFACT_SUBJECT")" \
    --arg vendorOutcome "$vendor_outcome" --arg vendorReason "$vendor_reason" \
    --arg providerOutcome "$provider_outcome" --arg providerReason "$provider_reason" \
    --arg verdict "$verdict" --arg reason "$reason" --arg teardownOutcome "$teardown_outcome" \
    --arg absence "$absence" --argjson providerIds "$provider_ids" --argjson providerAbsence "$provider_absence" \
    --argjson durable "$durable" --argjson required "$action_required" --argjson credentialIssued "$credential_issued" \
    --argjson setup "$setup_seconds" --argjson substrate "$substrate_seconds" \
    --argjson readiness "$readiness_seconds" --argjson actionSeconds "$action_seconds" \
    --argjson teardown "$teardown_seconds" --argjson debt "$debt" \
    --slurpfile preflight "$preflight" --slurpfile probes "$probes" --slurpfile chain "$checkpoint" '
    {apiVersion:"diene.atomi.cloud/ci-vendor-report/v1",repositoryRevision:$revision,
     workflow:{runId:$runId,runAttempt:$runAttempt,workflowRef:$workflowRef},
     lane:"ditto-vendor",profile:"ditto",buildMode:"build-local",actionId:$actionId,
     componentClass:$component,permissionRule:$permission,receiptId:$receiptId,
     instance:{allocationKey:$allocationKey,generationKey:$generationKey,substrateName:$substrateName,
       clusterId:$clusterId,osId:$preflight[0].os.id,osVersion:$preflight[0].os.version,
       k3sVersion:$preflight[0].k3s.version,kubernetesVersion:$preflight[0].k3s.kubernetesVersion,
       nodeCount:$preflight[0].k3s.nodeCount,capacity:$preflight[0].k3s.capacity},
     tooling:{gardenLockDigest:$garden,journeyManifestDigest:$vendorDigest,nscVersion:$nscVersion,
       nscArtifactDigest:$nscArtifactDigest,nscBinaryDigest:$nscBinaryDigest,
       sourceArchiveDigest:$sourceDigest,artifactSubjectDigest:$subjectDigest},
     vendorOutcome:{id:$actionId,outcome:$vendorOutcome,reasonCode:$vendorReason,required:$required,
       durationSeconds:$actionSeconds},
     providerCleanup:{outcome:$providerOutcome,reasonCode:$providerReason,objectIds:$providerIds,
       absenceProven:$providerAbsence,durableDebtRecord:$durable},
     credential:{issuer:"approved-environment-phase-broker",masked:($credentialIssued == 1),
       issuedAfterReadiness:($credentialIssued == 1),removed:($providerAbsence and $credentialIssued == 1),
       removalObserved:($providerAbsence and $credentialIssued == 1)},
     evidence:{leakageScan:{outcome:"Pass",reasonCode:"ScanPendingFinalisation",encodings:[],scannedPaths:[]},
       egressCanary:{outcome:(if ($probes[0] | length) >= 6 then "Pass" else "Fail" end),
         reasonCode:(if ($probes[0] | length) >= 6 then "HostAndPodNegativeProbesPassed" else "ProbeEvidenceIncomplete" end),
         mode:"allowlist",profileId:"ditto-vendor-v1",enforcement:"interim-in-guest-iptables-nft",
         platformStatus:"platform per-instance policy pending (support ask #4)",hostileProbes:($probes[0] // [])},
       shipment:{outcome:"Unavailable",reasonCode:"CollectedByOuterOrchestrator"}},
     teardown:{outcome:$teardownOutcome,reasonCode:(if $teardownOutcome == "Pass" then "ExactReceiptDestroyed" else "CleanupDebt" end),
       transitions:["ProviderCleanup:"+$providerOutcome,"GardenAndPolicyCleanup:"+$teardownOutcome],
       finalizerWaitSeconds:0,debt:$debt,absenceProof:$absence},checkpointChain:$chain[0],
     timings:{setupSeconds:$setup,substrateSeconds:$substrate,readinessSeconds:$readiness,
       journeysSeconds:$actionSeconds,teardownSeconds:$teardown},outcome:$verdict}
     + (if $reason == "" then {} else {reasonCode:$reason} end)' |
    diene_write_json "$evidence/vendor-report.driver.json"
}

vendor_package() {
  local exit_code=${1:?exit status required} reason=${2:-VendorFailed}
  local outcome=Pass
  ((exit_code == 0)) || outcome=Fail
  jq -n --arg outcome "$outcome" --arg reason "$reason" --argjson exitCode "$exit_code" \
    '{outcome:$outcome,reasonCode:$reason,exitCode:$exitCode}' |
    diene_write_json "$evidence/driver-status.json"
  install -m 0600 "$receipt" "$evidence/ci-receipt.json"
  install -d -m 0700 "$state/out"
  tar -cf "$state/out/proof.tar" -C "$state" evidence
  chmod 0600 "$state/out/proof.tar"
  (cd "$state/out" && sha256sum proof.tar >proof.sha256)
  chmod 0600 "$state/out/proof.sha256"
}

vendor_finalize() {
  local prior=${1:-0}
  ((finalized == 0)) || return "$prior"
  finalized=1
  local reason='' result=$prior evidence_digest
  if [[ -s $DIENE_REASON_FILE ]]; then IFS=$'\t' read -r reason _ <"$DIENE_REASON_FILE" || true; fi
  vendor_cleanup || {
    ((result != 0)) || result=$DIENE_REASON_EXIT
    [[ -n $reason ]] || reason=CleanupDebt
  }
  evidence_digest=$(diene_sha256_text "$DIENE_ACTION_ID|${reason:-Pass}|$provider_outcome")
  if ((result == 0)); then
    diene_checkpoint_append "$checkpoint" final-clean-pass Pass "$evidence_digest" false
    diene_checkpoint_seal "$checkpoint" true
    if [[ $vendor_outcome == Unavailable && $action_required == false ]]; then
      vendor_emit_report Unavailable "$vendor_reason"
    else
      vendor_emit_report "$vendor_outcome" ''
    fi
  else
    diene_checkpoint_append "$checkpoint" driver-failure Fail "$evidence_digest" false
    diene_checkpoint_seal "$checkpoint" false
    vendor_emit_report Fail "${reason:-VendorActionFailed}"
  fi
  vendor_package "$result" "${reason:-VendorCompleted}"
  return "$result"
}

vendor_on_exit() {
  local prior=$? rc=0
  trap - EXIT TERM INT HUP
  vendor_finalize "$prior" || rc=$?
  exit "$rc"
}
vendor_on_signal() {
  local rc=${1:?signal status required}
  printf 'VendorDriverCancelled\tsignal received\n' >"$DIENE_REASON_FILE"
  exit "$rc"
}

# Defaults ensure an early red path still packages a schema-representable
# report rather than losing all evidence.
jq -n --arg clusterId "$DIENE_NSC_CLUSTER_ID" '
  {outcome:"Fail",reasonCode:"PreflightNotCompleted",clusterId:$clusterId,
   os:{id:null,version:null,uid:0},k3s:{version:null,kubernetesVersion:null,nodeCount:null,capacity:null},
   network:{podCidrs:[],serviceCidrs:[],ipv6Disabled:false,namespaceIngress:false,publicBinding:false},
   storage:{defaultClass:null},policyBackend:{mechanism:"iptables",backend:"nf_tables",version:null},
   cacheAttached:false,platformStatus:"platform per-instance policy pending (support ask #4)"}' |
  diene_write_json "$evidence/preflight.json"
printf '[]\n' | diene_write_json "$evidence/hostile-probes.json"
trap vendor_on_exit EXIT
trap 'vendor_on_signal 143' TERM HUP
trap 'vendor_on_signal 130' INT

started=$SECONDS
export DIENE_PREFLIGHT_EVIDENCE="$evidence/preflight.json"
"$script_dir/environment-runner-preflight.sh" --output "$DIENE_PREFLIGHT_EVIDENCE"
diene_checkpoint_append "$checkpoint" instance-preflight Pass \
  "$(diene_file_digest "$DIENE_PREFLIGHT_EVIDENCE")" false

resolved="$evidence/egress-resolved.json"
policy="$evidence/policy.json"
l7="$evidence/l7-egress.json"
diene_resolve_egress_contract "$DIENE_EGRESS_CONTRACT" "$resolved"
diene_preflow_start
diene_apply_interim_policy "$resolved" "$policy" "$l7"
policy_applied=1
diene_verify_hostile_egress "$evidence/hostile-probes.json"
diene_receipt_patch "$receipt" '.namespace.policy.applied = true | .namespace.policy.hostileProbes = "Pass"'
diene_checkpoint_append "$checkpoint" egress-policy Pass "$(diene_file_digest "$policy")" false
setup_seconds=$((SECONDS - started))

substrate_started=$SECONDS
"$pls_bin" env up --profile ditto --build-mode build-local --artifact "$DIENE_ARTIFACT_DIGEST"
substrate_seconds=$((SECONDS - substrate_started))
runtime_file=$(diene_discover_runtime ditto "$(diene_allocation_key)" "$(diene_generation_key)")
substrate_name=$(jq -r '.substrate.name' "$runtime_file")
# shellcheck disable=SC2016
diene_receipt_patch "$receipt" '.runtimeFile = $path | .cleanup.reasonCode = "RuntimeBound"' --arg path "$runtime_file"
export DIENE_GARDEN_RUNTIME_FILE=$runtime_file
diene_checkpoint_append "$checkpoint" render-apply Pass \
  "$(diene_sha256_text "$substrate_name|$substrate_seconds")" false

readiness_started=$SECONDS
readiness="$evidence/readiness.json"
"$pls_bin" env doctor --profile ditto --json >"$readiness"
diene_schema_validate diene-readiness-v1.schema.json "$readiness" 'vendor readiness evidence'
jq -e '
  .outcome == "Pass" and any(.readiness[]; .id == "EnvironmentReady" and .outcome == "Pass") and
  ([.readiness[] | select(.required == true) | .outcome] | all(. == "Pass"))
' "$readiness" >/dev/null || diene_die EnvironmentNotReady 'vendor readiness did not converge'
readiness_seconds=$((SECONDS - readiness_started))
diene_checkpoint_append "$checkpoint" environment-ready Pass "$(diene_file_digest "$readiness")" false

"$broker" issue --action "$DIENE_ACTION_ID" --output "$credential_file" --evidence "$credential_evidence" ||
  diene_die VendorBrokerInterfaceUnavailable 'approved phase broker did not issue the vendor credential'
[[ -s $credential_file && ! -L $credential_file && $(stat -c %a "$credential_file") == 600 ]] ||
  diene_die VendorBrokerInterfaceUnavailable 'broker credential file is absent or not mode 0600'
jq -e '.outcome == "Pass" and .masked == true and .issuedAfterReadiness == true' \
  "$credential_evidence" >/dev/null ||
  diene_die VendorBrokerInterfaceUnavailable 'broker did not attest masked post-readiness issuance'
DIENE_VENDOR_CREDENTIAL=$(<"$credential_file")
export DIENE_VENDOR_CREDENTIAL
credential_issued=1

action_started=$SECONDS
vendor_outcome=Pass
vendor_reason=AssertionsSatisfied
action_rc=0
if diene_run_argv "$action" . setup; then
  :
else
  action_rc=$?
  vendor_outcome=Fail
  vendor_reason=SetupFailed
fi
if [[ $vendor_outcome == Pass ]]; then
  if diene_run_argv "$action" . probe; then
    :
  else
    action_rc=$?
    vendor_outcome=Fail
    vendor_reason=ProbeFailed
  fi
fi
# Exit 69 is the declared adapter signal for an unavailable sandbox. It is
# nonblocking only for an explicitly optional action; every other failure is
# still a real vendor failure.
if [[ $action_rc == 69 && $action_required == false ]]; then
  vendor_outcome=Unavailable
  vendor_reason=ProviderUnavailable
fi
action_seconds=$((SECONDS - action_started))
diene_checkpoint_append "$checkpoint" vendor-action \
  "$([[ $vendor_outcome == Pass ]] && printf Pass || printf Fail)" \
  "$(diene_sha256_text "$DIENE_ACTION_ID|$vendor_outcome|$action_seconds")" false
[[ $vendor_outcome != Fail ]] || diene_die VendorActionFailed "$DIENE_ACTION_ID failed"
diene_verify_endpoint_law "$evidence/endpoint-law.json"
