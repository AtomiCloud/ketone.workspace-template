#!/usr/bin/env bash
# Retained environment-k3d compatibility entrypoint.
#
#   orchestrate (default): trusted ordinary-runner controller for the exact
#     nsc create -> upload -> ssh -T -> collect -> destroy -> absence sequence.
#   driver: copied, credential-free on-instance core driver. A vendor input is
#     dispatched to environment-vendor-run.sh's driver mode.
#
# The two modes share source but not authority. The guest receives immutable
# files only and cannot create/list/destroy Namespace instances.
set -euo pipefail
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$script_dir/environment-lib.sh"

json_array_of() {
  if (($# == 0)); then
    printf '[]\n'
  else
    printf '%s\n' "$@" | jq -R . | jq -sc .
  fi
}

phase_digest() {
  diene_sha256_text "${1:?phase required}|${2:-}|${3:-}"
}

# ---------------------------------------------------------------------------
# Orchestrator mode.
# ---------------------------------------------------------------------------

ORCH_STATE=
ORCH_CLUSTER_ID=
ORCH_RECEIPT=
ORCH_RECEIPT_ID=
ORCH_KIND=core
ORCH_FIRST_RC=0
ORCH_FIRST_REASON=
ORCH_CLEANUP_DONE=0
ORCH_FINALIZED=0
ORCH_CREATE_OUTCOME=NotAttempted
ORCH_CREATE_REASON=CreateNotAttempted
ORCH_CREATE_SECONDS=0
ORCH_CREATE_DIGEST=$DIENE_ZERO_DIGEST
ORCH_TRANSFER_OUTCOME=NotAttempted
ORCH_TRANSFER_REASON=TransferNotAttempted
ORCH_TRANSFER_SECONDS=0
ORCH_TRANSFER_DIGEST=$DIENE_ZERO_DIGEST
ORCH_SSH_OUTCOME=NotAttempted
ORCH_SSH_REASON=SshNotAttempted
ORCH_SSH_SECONDS=0
ORCH_SSH_DIGEST=$DIENE_ZERO_DIGEST
ORCH_COLLECTION_OUTCOME=NotAttempted
ORCH_COLLECTION_REASON=CollectionNotAttempted
ORCH_COLLECTION_SECONDS=0
ORCH_COLLECTION_DIGEST=$DIENE_ZERO_DIGEST
ORCH_DESTROY_OUTCOME=NotAttempted
ORCH_DESTROY_REASON=DestroyNotAttempted
ORCH_DESTROY_SECONDS=0
ORCH_DESTROY_DIGEST=$DIENE_ZERO_DIGEST
ORCH_ABSENCE_OUTCOME=NotAttempted
ORCH_ABSENCE_REASON=AbsenceNotAttempted
ORCH_ABSENCE_SECONDS=0
ORCH_ABSENCE_DIGEST=$DIENE_ZERO_DIGEST
ORCH_STARTED=0

orchestrator_fail() {
  local rc=${1:?failure status required}
  local reason=${2:?failure reason required}
  if ((ORCH_FIRST_RC == 0)); then
    ORCH_FIRST_RC=$rc
    ORCH_FIRST_REASON=$reason
  fi
  diene_warn "$reason" "${3:-the Namespace lifecycle leg failed}"
}

orchestrator_patch_receipt_phase() {
  local phase=${1:?phase required} outcome=${2:?outcome required}
  local reason=${3:?reason required} seconds=${4:?seconds required} digest=${5:?digest required}
  [[ -f ${ORCH_RECEIPT:-} ]] || return 0
  diene_receipt_patch "$ORCH_RECEIPT" \
    ".namespace.$phase = {outcome:\$outcome,reasonCode:\$reason,durationSeconds:\$seconds,receiptDigest:\$digest}" \
    --arg outcome "$outcome" --arg reason "$reason" --argjson seconds "$seconds" --arg digest "$digest"
}

orchestrator_cleanup() {
  ((ORCH_CLEANUP_DONE == 0)) || return 0
  ORCH_CLEANUP_DONE=1
  [[ -n $ORCH_CLUSTER_ID ]] || {
    ORCH_DESTROY_OUTCOME=NotAttempted
    ORCH_DESTROY_REASON=NoExactClusterId
    ORCH_ABSENCE_OUTCOME=NotAttempted
    ORCH_ABSENCE_REASON=NoExactClusterId
    return 0
  }
  local nsc_bin started rc
  nsc_bin=$(diene_nsc_bin)
  started=$SECONDS
  rc=0
  "$nsc_bin" destroy --force "$ORCH_CLUSTER_ID" \
    >>"$DIENE_EVIDENCE_STAGING/stdout" 2>>"$DIENE_EVIDENCE_STAGING/stderr" || rc=$?
  ORCH_DESTROY_SECONDS=$((SECONDS - started))
  ORCH_DESTROY_DIGEST=$(phase_digest destroy "$ORCH_CLUSTER_ID" "$rc")
  if ((rc == 0)); then
    ORCH_DESTROY_OUTCOME=Pass
    ORCH_DESTROY_REASON=ExactClusterDestroyed
  else
    ORCH_DESTROY_OUTCOME=Fail
    ORCH_DESTROY_REASON=NamespaceDestroyFailed
    orchestrator_fail "$rc" NamespaceDestroyFailed "nsc destroy failed for exact cluster_id $ORCH_CLUSTER_ID"
  fi
  orchestrator_patch_receipt_phase destroy "$ORCH_DESTROY_OUTCOME" "$ORCH_DESTROY_REASON" \
    "$ORCH_DESTROY_SECONDS" "$ORCH_DESTROY_DIGEST"

  started=$SECONDS
  if diene_nsc_wait_absent "$ORCH_CLUSTER_ID"; then
    ORCH_ABSENCE_OUTCOME=Pass
    ORCH_ABSENCE_REASON=ExactClusterAbsent
  else
    ORCH_ABSENCE_OUTCOME=Fail
    ORCH_ABSENCE_REASON=NamespaceAbsenceUnproven
    orchestrator_fail "$DIENE_REASON_EXIT" NamespaceAbsenceUnproven \
      "exact cluster_id $ORCH_CLUSTER_ID remained present or list evidence was unavailable"
  fi
  ORCH_ABSENCE_SECONDS=$((SECONDS - started))
  ORCH_ABSENCE_DIGEST=$(phase_digest absence "$ORCH_CLUSTER_ID" "$ORCH_ABSENCE_OUTCOME")
  orchestrator_patch_receipt_phase absence "$ORCH_ABSENCE_OUTCOME" "$ORCH_ABSENCE_REASON" \
    "$ORCH_ABSENCE_SECONDS" "$ORCH_ABSENCE_DIGEST"
}

orchestrator_safe_extract() {
  local archive=${1:?archive required} target=${2:?target required}
  local listing
  listing=$(mktemp "${RUNNER_TEMP:-/tmp}/diene-tar.XXXXXX")
  tar -tf "$archive" >"$listing" || {
    rm -f -- "$listing"
    return 1
  }
  awk '
    /^\// {bad=1}
    /(^|\/)\.\.($|\/)/ {bad=1}
    !/^evidence\// {bad=1}
    END {exit bad ? 1 : 0}
  ' "$listing" || {
    rm -f -- "$listing"
    return 1
  }
  rm -f -- "$listing"
  install -d -m 0700 "$target"
  tar --extract --no-same-owner --no-same-permissions -f "$archive" -C "$target"
  while IFS= read -r -d '' link; do
    diene_warn EvidenceCollectionFailed "collected proof contains forbidden link $link"
    return 1
  done < <(find "$target" -type l -print0)
}

orchestrator_synthetic_report() {
  local target=${1:?synthetic report required}
  local journey_digest=$DIENE_ZERO_DIGEST component=K9 permission=ditto-vendor-demo
  if [[ -f ${DIENE_JOURNEY_MANIFEST:-} ]]; then
    journey_digest=$(diene_file_digest "$DIENE_JOURNEY_MANIFEST")
  fi
  if [[ $ORCH_KIND == vendor ]]; then
    component=$(jq -r --arg id "$DIENE_ACTION_ID" '.actions[] | select(.actionId == $id) | .componentClass' \
      "$DIENE_VENDOR_MANIFEST")
    permission=$(jq -r --arg id "$DIENE_ACTION_ID" '.actions[] | select(.actionId == $id) | .permissionRule' \
      "$DIENE_VENDOR_MANIFEST")
    jq -n \
      --arg revision "$GITHUB_SHA" --arg runId "$GITHUB_RUN_ID" --arg runAttempt "$GITHUB_RUN_ATTEMPT" \
      --arg workflowRef "$DIENE_BASE_WORKFLOW_REF" --arg actionId "$DIENE_ACTION_ID" \
      --arg component "$component" --arg permission "$permission" --arg receiptId "$ORCH_RECEIPT_ID" \
      --arg allocationKey "$(diene_allocation_key)" --arg generationKey "$(diene_generation_key)" \
      --arg garden "$DIENE_GARDEN_LOCK_DIGEST" --arg reason "${ORCH_FIRST_REASON:-NamespaceLifecycleFailed}" '
      {apiVersion:"diene.atomi.cloud/ci-vendor-report/v1",repositoryRevision:$revision,
       workflow:{runId:$runId,runAttempt:$runAttempt,workflowRef:$workflowRef},
       lane:"ditto-vendor",profile:"ditto",buildMode:"build-local",actionId:$actionId,
       componentClass:$component,permissionRule:$permission,receiptId:$receiptId,
       instance:{allocationKey:$allocationKey,generationKey:$generationKey},
       tooling:{gardenLockDigest:$garden,journeyManifestDigest:"sha256:0000000000000000000000000000000000000000000000000000000000000000"},
       vendorOutcome:{id:$actionId,outcome:"Fail",reasonCode:$reason,required:true,durationSeconds:0},
       providerCleanup:{outcome:"Unavailable",reasonCode:"DriverEvidenceUnavailable",objectIds:[],
         absenceProven:false,durableDebtRecord:("receipt:"+$receiptId)},
       evidence:{leakageScan:{outcome:"Pass",reasonCode:"ScanPendingFinalisation",encodings:[],scannedPaths:[]},
         egressCanary:{outcome:"Fail",reasonCode:"PolicyProofUnavailable"},
         shipment:{outcome:"Unavailable",reasonCode:"CollectionIncomplete"}},
       teardown:{outcome:"Fail",reasonCode:"LifecycleIncomplete",transitions:["NotAttempted"],
         finalizerWaitSeconds:0,debt:["driver proof unavailable"],absenceProof:"NotAttempted"},
       timings:{setupSeconds:0,substrateSeconds:0,readinessSeconds:0,journeysSeconds:0,teardownSeconds:0},
       outcome:"Fail",reasonCode:$reason}' | diene_write_json "$target"
  else
    jq -n \
      --arg revision "$GITHUB_SHA" --arg runId "$GITHUB_RUN_ID" --arg runAttempt "$GITHUB_RUN_ATTEMPT" \
      --arg workflowRef "$DIENE_BASE_WORKFLOW_REF" --arg lane "$DIENE_LANE" \
      --arg profile "$(diene_runtime_profile "$DIENE_LANE")" --arg buildMode "$(diene_build_mode "$DIENE_LANE")" \
      --arg artifact "$DIENE_ARTIFACT_DIGEST" --arg imageRef "$DIENE_SUBJECT_IMAGE_REF" \
      --arg producer "$DIENE_SUBJECT_PRODUCER_WORKFLOW_REF" --arg receiptId "$ORCH_RECEIPT_ID" \
      --arg allocationKey "$(diene_allocation_key)" --arg generationKey "$(diene_generation_key)" \
      --arg garden "$DIENE_GARDEN_LOCK_DIGEST" --arg journey "$journey_digest" \
      --arg reason "${ORCH_FIRST_REASON:-NamespaceLifecycleFailed}" '
      {apiVersion:"diene.atomi.cloud/ci-environment-report/v1",repositoryRevision:$revision,
       workflow:{runId:$runId,runAttempt:$runAttempt,workflowRef:$workflowRef},
       lane:$lane,profile:$profile,buildMode:$buildMode,
       subject:{artifactDigest:$artifact,imageRef:$imageRef,producerWorkflowRef:$producer},
       instance:{allocationKey:$allocationKey,generationKey:$generationKey},receiptId:$receiptId,
       tooling:{gardenLockDigest:$garden,journeyManifestDigest:$journey},readiness:null,
       journeys:[],coverage:[],
       evidence:{leakageScan:{outcome:"Pass",reasonCode:"ScanPendingFinalisation",encodings:[],scannedPaths:[]},
         egressCanary:{outcome:"Fail",reasonCode:"PolicyProofUnavailable"},
         shipment:{outcome:"Unavailable",reasonCode:"CollectionIncomplete"}},
       teardown:{outcome:"Fail",reasonCode:"LifecycleIncomplete",transitions:["NotAttempted"],
         finalizerWaitSeconds:0,debt:["driver proof unavailable"],absenceProof:"NotAttempted"},
       timings:{setupSeconds:0,substrateSeconds:0,readinessSeconds:0,journeysSeconds:0,teardownSeconds:0},
       outcome:"Fail",reasonCode:$reason}' | diene_write_json "$target"
  fi
}

orchestrator_finalize_report() {
  ((ORCH_FINALIZED == 0)) || return 0
  ORCH_FINALIZED=1
  [[ -n $ORCH_STATE ]] || return 0
  local collected="$ORCH_STATE/collected/evidence"
  local base_report="$collected/${ORCH_KIND}-report.driver.json"
  if [[ ! -f $base_report ]]; then
    base_report="$ORCH_STATE/${ORCH_KIND}-report.synthetic.json"
    orchestrator_synthetic_report "$base_report"
  fi

  local checkpoint="$collected/checkpoint-chain.json"
  if [[ ! -f $checkpoint ]]; then
    checkpoint="$ORCH_STATE/checkpoint-chain.failed.json"
    local input_digest
    input_digest=$(diene_sha256_text "$GITHUB_SHA|$DIENE_GARDEN_LOCK_DIGEST|$DIENE_ARTIFACT_DIGEST|$DIENE_LANE")
    diene_checkpoint_init "$checkpoint" "$input_digest"
    diene_checkpoint_append "$checkpoint" lifecycle-failure Fail \
      "$(phase_digest lifecycle "${ORCH_FIRST_REASON:-NamespaceLifecycleFailed}" "$ORCH_CLUSTER_ID")" false
    diene_checkpoint_seal "$checkpoint" false
  else
    if ! diene_checkpoint_validate "$checkpoint"; then
      orchestrator_fail "$DIENE_REASON_EXIT" CheckpointChainInvalid 'collected predecessor chain is invalid'
    fi
  fi

  local preflight="$collected/preflight.json" cluster_json os_id os_version k3s_version kubernetes_version
  local node_count capacity probes
  cluster_json=null
  [[ -z $ORCH_CLUSTER_ID ]] || cluster_json=$(jq -cn --arg value "$ORCH_CLUSTER_ID" '$value')
  os_id=null
  os_version=null
  k3s_version=null
  kubernetes_version=null
  node_count=null
  capacity=null
  if [[ -f $preflight ]]; then
    os_id=$(jq -c '.os.id' "$preflight")
    os_version=$(jq -c '.os.version' "$preflight")
    k3s_version=$(jq -c '.k3s.version' "$preflight")
    kubernetes_version=$(jq -c '.k3s.kubernetesVersion' "$preflight")
    node_count=$(jq -c '.k3s.nodeCount' "$preflight")
    capacity=$(jq -c '.k3s.capacity' "$preflight")
  fi
  probes='[{"id":"policy-proof-unavailable","outcome":"Fail","reasonCode":"NotCollected","required":true}]'
  [[ ! -f $collected/hostile-probes.json ]] || probes=$(jq -c . "$collected/hostile-probes.json")

  local driver_outcome driver_nonblocking=false
  driver_outcome=$(jq -r '.outcome' "$base_report")
  if [[ $ORCH_KIND == vendor ]] && jq -e '
    .outcome == "Unavailable" and .vendorOutcome.outcome == "Unavailable" and
    .vendorOutcome.required == false
  ' "$base_report" >/dev/null; then
    driver_nonblocking=true
  elif [[ $driver_outcome != Pass ]]; then
    orchestrator_fail "$DIENE_REASON_EXIT" "$(jq -r '.reasonCode // "DriverFailed"' "$base_report")" \
      'on-instance driver reported a red result'
  fi
  local lifecycle_outcome=Pass report_outcome=$driver_outcome report_reason=''
  for outcome in "$ORCH_CREATE_OUTCOME" "$ORCH_TRANSFER_OUTCOME" "$ORCH_SSH_OUTCOME" \
    "$ORCH_COLLECTION_OUTCOME" "$ORCH_DESTROY_OUTCOME" "$ORCH_ABSENCE_OUTCOME"; do
    [[ $outcome == Pass ]] || lifecycle_outcome=Fail
  done
  if ((ORCH_FIRST_RC != 0)) || [[ $lifecycle_outcome != Pass ]] ||
    [[ $driver_outcome != Pass && $driver_nonblocking != true ]]; then
    report_outcome=Fail
    report_reason=${ORCH_FIRST_REASON:-NamespaceLifecycleFailed}
  elif [[ $driver_nonblocking == true ]]; then
    report_reason=$(jq -r '.reasonCode' "$base_report")
  fi

  local lifecycle="$ORCH_STATE/namespace-lifecycle.json"
  jq -n \
    --argjson clusterId "$cluster_json" --arg venue "${DIENE_ORCHESTRATOR_VENUE:-namespace}" \
    --arg label "${DIENE_ORCHESTRATOR_LABEL:-nscloud-ubuntu-26.04-amd64-16x32}" \
    --arg fallback "${DIENE_ORCHESTRATOR_FALLBACK_REASON:-}" --arg outcome "$lifecycle_outcome" \
    --arg createOutcome "$ORCH_CREATE_OUTCOME" --arg createReason "$ORCH_CREATE_REASON" \
    --arg transferOutcome "$ORCH_TRANSFER_OUTCOME" --arg transferReason "$ORCH_TRANSFER_REASON" \
    --arg sshOutcome "$ORCH_SSH_OUTCOME" --arg sshReason "$ORCH_SSH_REASON" \
    --arg collectionOutcome "$ORCH_COLLECTION_OUTCOME" --arg collectionReason "$ORCH_COLLECTION_REASON" \
    --arg destroyOutcome "$ORCH_DESTROY_OUTCOME" --arg destroyReason "$ORCH_DESTROY_REASON" \
    --arg absenceOutcome "$ORCH_ABSENCE_OUTCOME" --arg absenceReason "$ORCH_ABSENCE_REASON" \
    --arg createDigest "$ORCH_CREATE_DIGEST" --arg transferDigest "$ORCH_TRANSFER_DIGEST" \
    --arg sshDigest "$ORCH_SSH_DIGEST" --arg collectionDigest "$ORCH_COLLECTION_DIGEST" \
    --arg destroyDigest "$ORCH_DESTROY_DIGEST" --arg absenceDigest "$ORCH_ABSENCE_DIGEST" \
    --argjson createSeconds "$ORCH_CREATE_SECONDS" --argjson transferSeconds "$ORCH_TRANSFER_SECONDS" \
    --argjson sshSeconds "$ORCH_SSH_SECONDS" --argjson collectionSeconds "$ORCH_COLLECTION_SECONDS" \
    --argjson destroySeconds "$ORCH_DESTROY_SECONDS" --argjson absenceSeconds "$ORCH_ABSENCE_SECONDS" '
    def phase($outcome;$reason;$seconds;$digest):
      {outcome:$outcome,reasonCode:$reason,durationSeconds:$seconds,receiptDigest:$digest};
    {clusterId:$clusterId,duration:"2h",ephemeral:true,endpointUsed:false,cacheAttached:false,
     orchestratorVenue:$venue,orchestratorLabel:$label,
     fallbackReason:(if $fallback == "" then null else $fallback end),
     create:phase($createOutcome;$createReason;$createSeconds;$createDigest),
     transfer:phase($transferOutcome;$transferReason;$transferSeconds;$transferDigest),
     ssh:phase($sshOutcome;$sshReason;$sshSeconds;$sshDigest),
     collection:phase($collectionOutcome;$collectionReason;$collectionSeconds;$collectionDigest),
     destroy:phase($destroyOutcome;$destroyReason;$destroySeconds;$destroyDigest),
     absence:phase($absenceOutcome;$absenceReason;$absenceSeconds;$absenceDigest),
     lateCleanupCanRewrite:false,outcome:$outcome}' | diene_write_json "$lifecycle"

  local source_digest subject_digest proof_digest total_seconds raw final_report
  source_digest=$(diene_file_digest "$ORCH_STATE/source.tar")
  subject_digest=$(diene_file_digest "$DIENE_ARTIFACT_SUBJECT")
  proof_digest=$ORCH_COLLECTION_DIGEST
  total_seconds=$((SECONDS - ORCH_STARTED))
  raw="$ORCH_STATE/${ORCH_KIND}-report.outer.raw.json"
  jq \
    --argjson lifecycle "$(jq -c . "$lifecycle")" --argjson checkpoint "$(jq -c . "$checkpoint")" \
    --argjson clusterId "$cluster_json" --argjson osId "$os_id" --argjson osVersion "$os_version" \
    --argjson k3sVersion "$k3s_version" --argjson kubernetesVersion "$kubernetes_version" \
    --argjson nodeCount "$node_count" --argjson capacity "$capacity" --argjson probes "$probes" \
    --arg nscVersion "$(diene_nsc_version)" --arg sourceDigest "$source_digest" \
    --arg subjectDigest "$subject_digest" --arg proofDigest "$proof_digest" \
    --arg profileId "$(diene_egress_profile "$DIENE_LANE")" --arg verdict "$report_outcome" \
    --arg reason "$report_reason" --argjson createSeconds "$ORCH_CREATE_SECONDS" \
    --argjson transferSeconds "$ORCH_TRANSFER_SECONDS" --argjson collectionSeconds "$ORCH_COLLECTION_SECONDS" \
    --argjson destroySeconds "$ORCH_DESTROY_SECONDS" --argjson totalSeconds "$total_seconds" '
    .instance += {clusterId:$clusterId,osId:$osId,osVersion:$osVersion,k3sVersion:$k3sVersion,
      kubernetesVersion:$kubernetesVersion,nodeCount:$nodeCount,capacity:$capacity} |
    .tooling += {nscVersion:$nscVersion,sourceArchiveDigest:$sourceDigest,artifactSubjectDigest:$subjectDigest} |
    .namespaceLifecycle = $lifecycle | .checkpointChain = $checkpoint |
    .evidence.egressCanary += {profileId:$profileId,enforcement:"interim-in-guest-iptables-nft",
      platformStatus:"platform per-instance policy pending (support ask #4)",hostileProbes:$probes} |
    .evidence.proofBundle = {outcome:(if $proofDigest == "sha256:0000000000000000000000000000000000000000000000000000000000000000" then "Fail" else "Pass" end),
      reasonCode:(if $proofDigest == "sha256:0000000000000000000000000000000000000000000000000000000000000000" then "CollectionUnavailable" else "CollectedBeforeDestroy" end),
      digest:$proofDigest,collectedBeforeDestroy:($proofDigest != "sha256:0000000000000000000000000000000000000000000000000000000000000000")} |
    .timings += {createToKubernetesReadySeconds:$createSeconds,driverTransferSetupSeconds:$transferSeconds,
      renderApplySeconds:(.timings.substrateSeconds // 0),collectionSeconds:$collectionSeconds,
      destroySeconds:$destroySeconds,totalColdSeconds:$totalSeconds} |
    .teardown.transitions += ["NamespaceDestroy:"+$lifecycle.destroy.outcome,
      "NamespaceAbsence:"+$lifecycle.absence.outcome] |
    .teardown.outcome = (if $verdict == "Fail" then "Fail" else "Pass" end) |
    .teardown.absenceProof = (if $lifecycle.absence.outcome == "Pass" then "ReceiptDestroyed" else "ReceiptRetainedAsDebt" end) |
    .outcome = $verdict |
    if $verdict == "Pass" then del(.reasonCode) else .reasonCode = $reason end
  ' "$base_report" | diene_write_json "$raw"

  final_report=${DIENE_CORE_REPORT:-$RUNNER_TEMP/diene-environment-report.v1.json}
  [[ $ORCH_KIND != vendor ]] || final_report=${DIENE_VENDOR_REPORT:-$RUNNER_TEMP/diene-vendor-report.v1.json}
  export DIENE_PROOF_BUNDLE_DIR=$ORCH_STATE
  "$script_dir/environment-report.sh" --kind "$ORCH_KIND" --input "$raw" --output "$final_report" || {
    orchestrator_fail "$DIENE_REASON_EXIT" EvidenceLeakDetected 'final outer proof-bundle scan or schema validation failed'
    return "$DIENE_REASON_EXIT"
  }

  local proof_dir="$ORCH_STATE/final-proof"
  install -d -m 0700 "$proof_dir"
  install -m 0600 "$final_report" "$proof_dir/$(basename -- "$final_report")"
  install -m 0600 "$lifecycle" "$proof_dir/namespace-lifecycle.json"
  install -m 0600 "$checkpoint" "$proof_dir/checkpoint-chain.json"
  [[ ! -f $ORCH_RECEIPT ]] || install -m 0600 "$ORCH_RECEIPT" "$proof_dir/ci-receipt.json"
  local final_bundle=${DIENE_PROOF_BUNDLE:-$RUNNER_TEMP/diene-proof-bundle.tar}
  tar -cf "$final_bundle" -C "$proof_dir" .
  chmod 0600 "$final_bundle"
  local report_digest
  report_digest=$(diene_file_digest "$final_report")
  printf 'subject_digest=%s\nreceipt_id=%s\n%s_report_digest=%s\nproof_bundle=%s\n' \
    "$DIENE_ARTIFACT_DIGEST" "$ORCH_RECEIPT_ID" "$ORCH_KIND" "$report_digest" "$final_bundle" \
    >>"${GITHUB_OUTPUT:-/dev/null}"
  local core_digest='' vendor_digest=''
  if [[ $ORCH_KIND == core ]]; then core_digest=$report_digest; else vendor_digest=$report_digest; fi
  diene_validate_report_namespace "$DIENE_LANE" "$core_digest" "$vendor_digest"
  ((ORCH_FIRST_RC == 0))
}

orchestrator_on_exit() {
  local prior=$?
  trap - EXIT TERM INT HUP
  ((prior == 0)) || orchestrator_fail "$prior" "${ORCH_FIRST_REASON:-NamespaceLifecycleFailed}" 'orchestrator exited non-zero'
  orchestrator_cleanup
  local final_rc=0
  orchestrator_finalize_report || final_rc=$?
  ((prior == 0 && ORCH_FIRST_RC == 0 && final_rc == 0)) || {
    ((ORCH_FIRST_RC != 0)) && exit "$ORCH_FIRST_RC"
    ((prior != 0)) && exit "$prior"
    exit "$final_rc"
  }
  exit 0
}

orchestrator_on_signal() {
  local rc=${1:?signal status required}
  orchestrator_fail "$rc" OrchestratorCancelled 'signal received during Namespace lifecycle'
  exit "$rc"
}

orchestrate() {
  diene_validate_inputs
  diene_require_command jq
  diene_require_command sha256sum
  diene_require_command tar
  diene_require_command git
  diene_require_command "${DIENE_SCHEMA_VALIDATOR_BIN:-check-jsonschema}"
  diene_require_command "$(diene_nsc_bin)"
  ORCH_KIND=core
  [[ $DIENE_LANE != ditto-vendor ]] || ORCH_KIND=vendor
  ORCH_RECEIPT_ID=$(diene_receipt_id)
  ORCH_STATE="${RUNNER_TEMP:?}/diene-namespace/$ORCH_RECEIPT_ID"
  install -d -m 0700 "$ORCH_STATE" "$ORCH_STATE/staging" "$ORCH_STATE/collected"
  export DIENE_EVIDENCE_STAGING="$ORCH_STATE/staging"
  for surface in stdout stderr argv environ; do
    : >"$DIENE_EVIDENCE_STAGING/$surface"
    chmod 0600 "$DIENE_EVIDENCE_STAGING/$surface"
  done
  printf '%q ' "$0" "$@" >"$DIENE_EVIDENCE_STAGING/argv"
  printf '\n' >>"$DIENE_EVIDENCE_STAGING/argv"
  env | grep -v '^DIENE_LEAK_CANARY=' | LC_ALL=C sort >"$DIENE_EVIDENCE_STAGING/environ"

  # All cheap refusals and immutable materialization happen before traps can
  # observe a created cluster because no substrate exists yet.
  "$script_dir/environment-profile-contract.sh" --validate-prerequisites
  diene_prepare_egress_contract "$ORCH_STATE/egress-contract.json"
  if [[ -n ${DIENE_SOURCE_ARCHIVE:-} ]]; then
    [[ -f $DIENE_SOURCE_ARCHIVE && ! -L $DIENE_SOURCE_ARCHIVE ]] ||
      diene_die InputContractInvalid 'provided source archive is not a regular file'
    install -m 0600 "$DIENE_SOURCE_ARCHIVE" "$ORCH_STATE/source.tar"
  else
    git cat-file -e "$GITHUB_SHA^{commit}" || diene_die UntrustedSubject 'source SHA does not resolve'
    git archive --format=tar --output="$ORCH_STATE/source.tar" "$GITHUB_SHA"
    chmod 0600 "$ORCH_STATE/source.tar"
  fi
  tar -tf "$ORCH_STATE/source.tar" | grep -Fxq 'scripts/ci/environment-k3d-run.sh' ||
    diene_die UntrustedSubject 'source archive does not carry the pinned driver'
  tar -tf "$ORCH_STATE/source.tar" | grep -Fxq 'schemas/ci/diene-environment-report-v1.schema.json' ||
    diene_die UntrustedSubject 'source archive does not carry the pinned report schemas'

  local nsc_bin nsc_version source_digest subject_digest contract_digest create_started create_rc
  nsc_bin=$(diene_nsc_bin)
  nsc_version=$(diene_nsc_version)
  source_digest=$(diene_file_digest "$ORCH_STATE/source.tar")
  subject_digest=$(diene_file_digest "$DIENE_ARTIFACT_SUBJECT")
  contract_digest=$(diene_file_digest "$ORCH_STATE/egress-contract.json")
  ORCH_STARTED=$SECONDS
  trap orchestrator_on_exit EXIT
  trap 'orchestrator_on_signal 143' TERM HUP
  trap 'orchestrator_on_signal 130' INT

  local -a create=("$nsc_bin" create --ephemeral --duration 2h --wait_kube_system \
    --cidfile "$ORCH_STATE/cluster.cid" --output_json_to "$ORCH_STATE/create.json" --output json \
    --purpose "diene-ci-k3d/v1 $DIENE_LANE" --unique_tag "$ORCH_RECEIPT_ID" \
    --label "diene_receipt=$ORCH_RECEIPT_ID" --label "diene_run=$GITHUB_RUN_ID" \
    --label "diene_attempt=$GITHUB_RUN_ATTEMPT")
  [[ -z ${DIENE_NSC_MACHINE_TYPE:-} ]] || create+=(--machine_type "$DIENE_NSC_MACHINE_TYPE")
  create_started=$SECONDS
  create_rc=0
  "${create[@]}" >>"$DIENE_EVIDENCE_STAGING/stdout" 2>>"$DIENE_EVIDENCE_STAGING/stderr" || create_rc=$?
  ORCH_CREATE_SECONDS=$((SECONDS - create_started))
  if [[ -s $ORCH_STATE/cluster.cid && -s $ORCH_STATE/create.json ]]; then
    ORCH_CLUSTER_ID=$(diene_nsc_extract_cluster_id "$ORCH_STATE/cluster.cid" "$ORCH_STATE/create.json")
    ORCH_CREATE_DIGEST=$(diene_file_digest "$ORCH_STATE/create.json")
    ORCH_RECEIPT=$(diene_arm_receipt "$ORCH_RECEIPT_ID" "$ORCH_CLUSTER_ID" \
      "$ORCH_CREATE_DIGEST" "$ORCH_CREATE_SECONDS" false)
  fi
  if ((create_rc != 0)); then
    ORCH_CREATE_OUTCOME=Fail
    ORCH_CREATE_REASON=NamespaceCreateFailed
    orchestrator_fail "$create_rc" NamespaceCreateFailed 'nsc create did not succeed'
    return "$create_rc"
  fi
  [[ -n $ORCH_CLUSTER_ID ]] || diene_die NamespaceIdentityMismatch 'create succeeded without an exact agreed cluster_id'
  ORCH_CREATE_OUTCOME=Pass
  ORCH_CREATE_REASON=ExactClusterIdBound

  jq -n \
    --arg repositoryId "$GITHUB_REPOSITORY_ID" --arg repositoryKey "$GITHUB_REPOSITORY" \
    --arg sourceSha "$GITHUB_SHA" --arg runId "$GITHUB_RUN_ID" --arg runAttempt "$GITHUB_RUN_ATTEMPT" \
    --arg workflowRef "$DIENE_BASE_WORKFLOW_REF" --arg lane "$DIENE_LANE" \
    --arg garden "$DIENE_GARDEN_LOCK_DIGEST" --arg artifact "$DIENE_ARTIFACT_DIGEST" \
    --arg provenance "${DIENE_ARTIFACT_PROVENANCE_REF:-}" --arg attestation "${DIENE_ARTIFACT_ATTESTATION_DIGEST:-}" \
    --arg journey "${DIENE_JOURNEY_MANIFEST:-}" --arg vendor "${DIENE_VENDOR_MANIFEST:-}" \
    --arg action "${DIENE_ACTION_ID:-}" --arg fixture "${DIENE_FIXTURE_ID:-}" \
    --arg closure "${DIENE_CLOSURE_DIGEST:-}" --arg closureRef "${DIENE_CLOSURE_BUNDLE_REF:-}" \
    --arg closureSignature "${DIENE_CLOSURE_SIGNATURE_BUNDLE_DIGEST:-}" \
    --arg closureRoot "${DIENE_CLOSURE_TRUST_ROOT_DIGEST:-}" --arg clusterId "$ORCH_CLUSTER_ID" \
    --arg nscVersion "$nsc_version" --arg sourceDigest "$source_digest" --arg subjectDigest "$subject_digest" \
    --arg contractDigest "$contract_digest" --arg canaryImage "$DIENE_EGRESS_CANARY_IMAGE" \
    --arg l7 "${DIENE_EGRESS_L7_ENFORCER_BIN:-}" --arg probe "${DIENE_EGRESS_PROBE_BIN:-}" \
    --arg vendorBroker "${DIENE_VENDOR_CREDENTIAL_BROKER_BIN:-}" \
    --arg k3s "${DIENE_ADMITTED_K3S_VERSION:-v1.33.1+k3s1}" \
    --arg serviceCidr "${DIENE_K3S_SERVICE_CIDR:-10.143.0.0/16}" \
    --arg venue "${DIENE_ORCHESTRATOR_VENUE:-namespace}" \
    --arg label "${DIENE_ORCHESTRATOR_LABEL:-nscloud-ubuntu-26.04-amd64-16x32}" \
    --arg fallback "${DIENE_ORCHESTRATOR_FALLBACK_REASON:-}" '
    {apiVersion:"diene.atomi.cloud/ci-driver-inputs/v1",trustedRuntimeContext:"protected-base",
     duration:"2h",platformPolicyStatus:"platform per-instance policy pending (support ask #4)",
     owner:{repositoryId:$repositoryId,repositoryKey:$repositoryKey,sourceSha:$sourceSha,
       runId:$runId,runAttempt:$runAttempt,workflowRef:$workflowRef},lane:$lane,
     gardenLockDigest:$garden,artifact:{digest:$artifact,provenanceRef:$provenance,
       attestationDigest:$attestation},
     selectors:{journeyManifest:$journey,vendorManifest:$vendor,actionId:$action,fixtureId:$fixture},
     closure:{digest:$closure,bundleRef:$closureRef,signatureBundleDigest:$closureSignature,
       trustRootDigest:$closureRoot},clusterId:$clusterId,nscVersion:$nscVersion,
     sourceArchiveDigest:$sourceDigest,artifactSubjectDigest:$subjectDigest,
     admittedK3sVersion:$k3s,admittedServiceCidr:$serviceCidr,cacheAttached:false,
     egress:{contractDigest:$contractDigest,canaryImage:$canaryImage,l7Enforcer:$l7,probeBin:$probe},
     vendorCredentialBroker:$vendorBroker,
     orchestrator:{venue:$venue,label:$label,fallbackReason:(if $fallback == "" then null else $fallback end)}}' |
    diene_write_json "$ORCH_STATE/inputs.json"

  local transfer_started=$SECONDS transfer_rc=0
  "$nsc_bin" instance upload "$ORCH_CLUSTER_ID" "$ORCH_STATE/source.tar" /run/diene-ci/source.tar --mkdir \
    >>"$DIENE_EVIDENCE_STAGING/stdout" 2>>"$DIENE_EVIDENCE_STAGING/stderr" || transfer_rc=$?
  ((transfer_rc != 0)) || "$nsc_bin" instance upload "$ORCH_CLUSTER_ID" "$ORCH_STATE/inputs.json" \
    /run/diene-ci/inputs.json --mkdir >>"$DIENE_EVIDENCE_STAGING/stdout" 2>>"$DIENE_EVIDENCE_STAGING/stderr" || transfer_rc=$?
  ((transfer_rc != 0)) || "$nsc_bin" instance upload "$ORCH_CLUSTER_ID" "$DIENE_ARTIFACT_SUBJECT" \
    /run/diene-ci/artifact-subject.json --mkdir >>"$DIENE_EVIDENCE_STAGING/stdout" 2>>"$DIENE_EVIDENCE_STAGING/stderr" || transfer_rc=$?
  ((transfer_rc != 0)) || "$nsc_bin" instance upload "$ORCH_CLUSTER_ID" "$ORCH_STATE/egress-contract.json" \
    /run/diene-ci/egress-contract.json --mkdir >>"$DIENE_EVIDENCE_STAGING/stdout" 2>>"$DIENE_EVIDENCE_STAGING/stderr" || transfer_rc=$?
  ((transfer_rc != 0)) || "$nsc_bin" instance upload "$ORCH_CLUSTER_ID" "$ORCH_RECEIPT" \
    /run/diene-ci/receipt.json --mkdir >>"$DIENE_EVIDENCE_STAGING/stdout" 2>>"$DIENE_EVIDENCE_STAGING/stderr" || transfer_rc=$?
  ORCH_TRANSFER_SECONDS=$((SECONDS - transfer_started))
  ORCH_TRANSFER_DIGEST=$(phase_digest transfer "$source_digest" "$contract_digest")
  if ((transfer_rc != 0)); then
    ORCH_TRANSFER_OUTCOME=Fail
    ORCH_TRANSFER_REASON=NamespaceTransferFailed
    orchestrator_fail "$transfer_rc" NamespaceTransferFailed 'fixed immutable upload failed'
    return "$transfer_rc"
  fi
  ORCH_TRANSFER_OUTCOME=Pass
  ORCH_TRANSFER_REASON=ImmutableInputsUploaded

  local remote_command ssh_started ssh_rc=0
  # The command is intentionally expanded only by the remote shell.
  # shellcheck disable=SC2016
  remote_command='set -eu; umask 077; test "$(id -u)" = 0; install -d -m 0700 /run/diene-ci/source /run/diene-ci/tmp /run/diene-ci/evidence /run/diene-ci/receipts /run/diene-ci/out; tar -xf /run/diene-ci/source.tar -C /run/diene-ci/source; install -m 0600 /run/diene-ci/receipt.json /run/diene-ci/receipts/exact.json; cd /run/diene-ci/source; command -v nix >/dev/null; exec nix --extra-experimental-features "nix-command flakes" develop .#ci -c ./scripts/ci/environment-k3d-run.sh driver /run/diene-ci'
  ssh_started=$SECONDS
  "$nsc_bin" ssh "$ORCH_CLUSTER_ID" -T "$remote_command" \
    >>"$DIENE_EVIDENCE_STAGING/stdout" 2>>"$DIENE_EVIDENCE_STAGING/stderr" || ssh_rc=$?
  ORCH_SSH_SECONDS=$((SECONDS - ssh_started))
  ORCH_SSH_DIGEST=$(phase_digest ssh "$ORCH_CLUSTER_ID" "$ssh_rc")
  if ((ssh_rc == 0)); then
    ORCH_SSH_OUTCOME=Pass
    ORCH_SSH_REASON=NonInteractiveDriverCompleted
  else
    ORCH_SSH_OUTCOME=Fail
    ORCH_SSH_REASON=NamespaceSshDriverFailed
    orchestrator_fail "$ssh_rc" NamespaceSshDriverFailed 'nsc ssh -T driver leg failed'
  fi

  local collection_started=$SECONDS collection_rc=0
  "$nsc_bin" instance download "$ORCH_CLUSTER_ID" /run/diene-ci/out/proof.tar \
    "$ORCH_STATE/collected/proof.tar" --mkdir >>"$DIENE_EVIDENCE_STAGING/stdout" \
    2>>"$DIENE_EVIDENCE_STAGING/stderr" || collection_rc=$?
  ((collection_rc != 0)) || "$nsc_bin" instance download "$ORCH_CLUSTER_ID" /run/diene-ci/out/proof.sha256 \
    "$ORCH_STATE/collected/proof.sha256" --mkdir >>"$DIENE_EVIDENCE_STAGING/stdout" \
    2>>"$DIENE_EVIDENCE_STAGING/stderr" || collection_rc=$?
  if ((collection_rc == 0)); then
    (cd "$ORCH_STATE/collected" && sha256sum -c proof.sha256 >/dev/null) || collection_rc=$?
  fi
  if ((collection_rc == 0)); then
    orchestrator_safe_extract "$ORCH_STATE/collected/proof.tar" "$ORCH_STATE/collected" || collection_rc=$?
  fi
  ORCH_COLLECTION_SECONDS=$((SECONDS - collection_started))
  if ((collection_rc == 0)); then
    ORCH_COLLECTION_OUTCOME=Pass
    ORCH_COLLECTION_REASON=FixedProofBundleCollected
    ORCH_COLLECTION_DIGEST=$(diene_file_digest "$ORCH_STATE/collected/proof.tar")
    if [[ -f $ORCH_STATE/collected/evidence/ci-receipt.json ]]; then
      local collected_receipt=$ORCH_STATE/collected/evidence/ci-receipt.json
      diene_validate_receipt_owner "$collected_receipt" "$ORCH_CLUSTER_ID"
      install -m 0600 "$collected_receipt" "$ORCH_RECEIPT"
    fi
    if [[ -f $ORCH_STATE/collected/evidence/driver-status.json ]] &&
      ! jq -e '.outcome == "Pass" and .exitCode == 0' \
        "$ORCH_STATE/collected/evidence/driver-status.json" >/dev/null; then
      orchestrator_fail "$DIENE_REASON_EXIT" DriverFailed 'driver status is red'
    fi
  else
    ORCH_COLLECTION_OUTCOME=Fail
    ORCH_COLLECTION_REASON=EvidenceCollectionFailed
    ORCH_COLLECTION_DIGEST=$DIENE_ZERO_DIGEST
    orchestrator_fail "$collection_rc" EvidenceCollectionFailed 'fixed proof download, digest, or extraction failed'
  fi
  return "$ORCH_FIRST_RC"
}

# A separate workflow `if: always()` step invokes this mode. The normal
# orchestrator EXIT trap has already destroyed and proved absence; this mode
# re-proves that terminal state. If the runner step died before its trap ran,
# it may recover only the exact cidfile/metadata/receipt-bound cluster_id. A
# recovery is deliberately returned red: late cleanup closes debt but cannot
# rewrite the failed run green.
orchestrator_cleanup_command() {
  diene_validate_inputs
  diene_require_command jq
  diene_require_command tar
  diene_require_command "$(diene_nsc_bin)"
  ORCH_RECEIPT_ID=$(diene_receipt_id)
  ORCH_STATE="${RUNNER_TEMP:?}/diene-namespace/$ORCH_RECEIPT_ID"
  ORCH_RECEIPT=$(diene_receipt_path "$ORCH_RECEIPT_ID")
  local lifecycle="$ORCH_STATE/namespace-lifecycle.json"
  local cluster_id=''

  if [[ -f $ORCH_RECEIPT ]]; then
    cluster_id=$(jq -er '.namespace.clusterId | select(type == "string" and length > 0)' "$ORCH_RECEIPT") ||
      diene_die NamespaceIdentityMismatch 'receipt carries no exact Namespace cluster_id'
    diene_validate_receipt_owner "$ORCH_RECEIPT" "$cluster_id"
  elif [[ -s $ORCH_STATE/cluster.cid && -s $ORCH_STATE/create.json ]]; then
    cluster_id=$(diene_nsc_extract_cluster_id "$ORCH_STATE/cluster.cid" "$ORCH_STATE/create.json")
  fi

  if [[ -f $lifecycle ]]; then
    local recorded
    recorded=$(jq -er '.clusterId | select(type == "string" and length > 0)' "$lifecycle") ||
      diene_die NamespaceIdentityMismatch 'lifecycle evidence carries no exact cluster_id'
    [[ -z $cluster_id || $cluster_id == "$recorded" ]] ||
      diene_die NamespaceIdentityMismatch 'receipt and lifecycle cluster_id disagree'
    cluster_id=$recorded
    diene_require_safe_id cluster_id "$cluster_id"
    if jq -e '
      .duration == "2h" and .ephemeral == true and .lateCleanupCanRewrite == false and
      .destroy.outcome == "Pass" and .absence.outcome == "Pass"
    ' "$lifecycle" >/dev/null && diene_nsc_absent "$cluster_id"; then
      [[ -s ${DIENE_PROOF_BUNDLE:-$RUNNER_TEMP/diene-proof-bundle.tar} ]] ||
        diene_die EvidenceCollectionFailed 'terminal proof bundle is absent after successful lifecycle convergence'
      printf 'NamespaceLifecycleConverged: %s\n' "$cluster_id"
      return 0
    fi
  fi

  [[ -n $cluster_id ]] ||
    diene_die NamespaceIdentityMismatch 'no exact agreed cluster_id exists; refusing broad cleanup'
  local nsc_bin rc=0 absent=false
  nsc_bin=$(diene_nsc_bin)
  "$nsc_bin" destroy --force "$cluster_id" || rc=$?
  if diene_nsc_wait_absent "$cluster_id"; then absent=true; fi
  install -d -m 0700 "$ORCH_STATE/final-proof"
  jq -n --arg clusterId "$cluster_id" --argjson destroyExit "$rc" --argjson absent "$absent" '
    {outcome:"Fail",reasonCode:"LateExactCleanupCannotRewriteRun",clusterId:$clusterId,
     destroyExit:$destroyExit,absenceProven:$absent,lateCleanupCanRewrite:false}' |
    diene_write_json "$ORCH_STATE/final-proof/late-cleanup.json"
  diene_die LateCleanupCannotRewriteRun \
    "exact cluster_id $cluster_id was handled after the primary lifecycle; a fresh run is required"
}

orchestrator_verify_lifecycle() {
  local bundle=${1:?proof bundle required}
  diene_validate_inputs
  diene_require_command jq
  diene_require_command tar
  [[ -f $bundle && ! -L $bundle ]] ||
    diene_die EvidenceCollectionFailed 'workflow-owned lifecycle proof bundle is absent or unsafe'
  local listing extract
  listing=$(mktemp "${RUNNER_TEMP:-/tmp}/diene-lifecycle-list.XXXXXX")
  extract=$(mktemp -d "${RUNNER_TEMP:-/tmp}/diene-lifecycle-proof.XXXXXX")
  trap 'rm -f -- "$listing"; rm -r -- "$extract"' RETURN
  tar -tf "$bundle" >"$listing" || diene_die EvidenceCollectionFailed 'lifecycle proof tar is unreadable'
  awk '
    /^\// || /(^|\/)\.\.($|\/)/ {bad=1}
    !/^\.\/$/ && !/^\.\/(diene-environment-report\.v1\.json|diene-vendor-report\.v1\.json|namespace-lifecycle\.json|checkpoint-chain\.json|ci-receipt\.json)$/ {bad=1}
    END {exit bad ? 1 : 0}
  ' "$listing" || diene_die EvidenceCollectionFailed 'lifecycle proof has an unexpected or unsafe member'
  tar --extract --no-same-owner --no-same-permissions -f "$bundle" -C "$extract"
  find "$extract" -type l -print -quit | grep -q . &&
    diene_die EvidenceCollectionFailed 'lifecycle proof contains a link'

  local schema=diene-environment-report-v1.schema.json
  local report="$extract/diene-environment-report.v1.json"
  if [[ $DIENE_LANE == ditto-vendor ]]; then
    schema=diene-vendor-report-v1.schema.json
    report="$extract/diene-vendor-report.v1.json"
  fi
  diene_schema_validate "$schema" "$report" \
    'workflow-owned terminal report'
  local lifecycle="$extract/namespace-lifecycle.json" checkpoint="$extract/checkpoint-chain.json"
  [[ -f $lifecycle && -f $checkpoint ]] ||
    diene_die EvidenceCollectionFailed 'terminal lifecycle or checkpoint evidence is absent'
  local cluster_id receipt_id
  cluster_id=$(jq -er '.clusterId | select(type == "string" and length > 0)' "$lifecycle") ||
    diene_die NamespaceIdentityMismatch 'terminal lifecycle has no exact cluster_id'
  receipt_id=$(diene_receipt_id)
  diene_require_safe_id cluster_id "$cluster_id"
  jq -e \
    --arg sha "$GITHUB_SHA" --arg runId "$GITHUB_RUN_ID" --arg runAttempt "$GITHUB_RUN_ATTEMPT" \
    --arg lane "$DIENE_LANE" --arg receipt "$receipt_id" --arg cluster "$cluster_id" '
    .repositoryRevision == $sha and .workflow.runId == $runId and
    .workflow.runAttempt == $runAttempt and .lane == $lane and .receiptId == $receipt and
    .instance.clusterId == $cluster and .namespaceLifecycle.clusterId == $cluster and
    .namespaceLifecycle.duration == "2h" and .namespaceLifecycle.ephemeral == true and
    .namespaceLifecycle.endpointUsed == false and .namespaceLifecycle.cacheAttached == false and
    .namespaceLifecycle.lateCleanupCanRewrite == false and
    ([.namespaceLifecycle.create,.namespaceLifecycle.transfer,.namespaceLifecycle.ssh,
      .namespaceLifecycle.collection,.namespaceLifecycle.destroy,.namespaceLifecycle.absence] |
      all(.outcome == "Pass")) and
    .namespaceLifecycle.outcome == "Pass" and
    (.outcome == "Pass" or
      (.outcome == "Unavailable" and .vendorOutcome.outcome == "Unavailable" and
       .vendorOutcome.required == false)) and
    .evidence.proofBundle.outcome == "Pass" and
    .evidence.egressCanary.platformStatus ==
      "platform per-instance policy pending (support ask #4)" and
    .checkpointChain.validated == true and .checkpointChain.finalCleanPass == true and
    .checkpointChain.resumedLegs == 0 and
    .checkpointChain.checkpoints[-1].id == "final-clean-pass"
  ' "$report" >/dev/null ||
    diene_die NamespaceLifecycleFailed 'terminal report is not a green exact-id lifecycle proof'
  diene_checkpoint_validate "$checkpoint"
  jq -e '.validated == true and .finalCleanPass == true and .resumedLegs == 0' "$checkpoint" >/dev/null ||
    diene_die FinalCleanPassRequired 'terminal checkpoint chain is not a clean full pass'
  if [[ -f $extract/ci-receipt.json ]]; then
    diene_validate_receipt_owner "$extract/ci-receipt.json" "$cluster_id"
  fi
  printf 'NamespaceLifecycleVerified: %s\n' "$cluster_id"
}

# ---------------------------------------------------------------------------
# On-instance core driver mode.
# ---------------------------------------------------------------------------

DRIVER_STATE=
DRIVER_RUNTIME_DIR=
DRIVER_RECEIPT=
DRIVER_CHECKPOINT=
DRIVER_RESULTS=
DRIVER_COVERAGE=
DRIVER_READINESS=
DRIVER_POLICY_APPLIED=0
DRIVER_CLEANUP_DONE=0
DRIVER_CLEANUP_RC=0
DRIVER_FINALIZED=0
DRIVER_SETUP_SECONDS=0
DRIVER_SUBSTRATE_SECONDS=0
DRIVER_READINESS_SECONDS=0
DRIVER_JOURNEY_SECONDS=0
DRIVER_TEARDOWN_SECONDS=0
DRIVER_RUNTIME_FILE=
DRIVER_SUBSTRATE_NAME=
DRIVER_STARTED=0

driver_cleanup() {
  ((DRIVER_CLEANUP_DONE == 0)) || return "$DRIVER_CLEANUP_RC"
  DRIVER_CLEANUP_DONE=1
  local started=$SECONDS failed=0
  if [[ -n $DRIVER_RUNTIME_FILE ]]; then
    "$script_dir/environment-receipt-sweep.sh" --repository-id "$GITHUB_REPOSITORY_ID" \
      --run-id "$GITHUB_RUN_ID" --run-attempt "$GITHUB_RUN_ATTEMPT" \
      --receipt-id "$(diene_receipt_id)" || failed=1
  elif [[ -f $DRIVER_RECEIPT ]]; then
    diene_receipt_patch "$DRIVER_RECEIPT" \
      '.cleanup = {outcome:"Pass",reasonCode:"NoGardenRuntimeCreated",debt:[]}'
  fi
  if ((DRIVER_POLICY_APPLIED)); then
    diene_remove_interim_policy || failed=1
  fi
  DRIVER_TEARDOWN_SECONDS=$((SECONDS - started))
  DRIVER_CLEANUP_RC=$failed
  return "$failed"
}

driver_emit_report() {
  local verdict=${1:?verdict required} reason=${2:-}
  local preflight="$DRIVER_RUNTIME_DIR/preflight.json" probes="$DRIVER_RUNTIME_DIR/hostile-probes.json"
  local endpoint="$DRIVER_RUNTIME_DIR/endpoint-law.json" transitions debt teardown_outcome absence
  transitions='["GardenExactDown:Pass","InterimPolicyRemoved:Pass"]'
  debt='[]'
  teardown_outcome=Pass
  absence=ReceiptDestroyed
  if ((DRIVER_CLEANUP_RC != 0)); then
    transitions='["GardenOrPolicyCleanup:Fail"]'
    debt='["on-instance exact cleanup did not converge"]'
    teardown_outcome=Fail
    absence=ReceiptRetainedAsDebt
  fi
  [[ -s $DRIVER_READINESS ]] || printf 'null\n' >"$DRIVER_READINESS"
  local journeys coverage
  journeys=$(jq -sc . "$DRIVER_RESULTS")
  coverage=$(jq -sc . "$DRIVER_COVERAGE")
  local journey_digest environment_digest=''
  journey_digest=$(diene_file_digest "$DIENE_JOURNEY_MANIFEST")
  [[ ! -f ${DIENE_ENVIRONMENT_LOCK:-.diene/ci/environment-lock.v1.json} ]] ||
    environment_digest=$(diene_file_digest "${DIENE_ENVIRONMENT_LOCK:-.diene/ci/environment-lock.v1.json}")
  jq -n \
    --arg revision "$GITHUB_SHA" --arg runId "$GITHUB_RUN_ID" --arg runAttempt "$GITHUB_RUN_ATTEMPT" \
    --arg workflowRef "$DIENE_BASE_WORKFLOW_REF" --arg lane "$DIENE_LANE" \
    --arg profile "$(diene_runtime_profile "$DIENE_LANE")" --arg buildMode "$(diene_build_mode "$DIENE_LANE")" \
    --arg artifact "$DIENE_ARTIFACT_DIGEST" --arg imageRef "$DIENE_SUBJECT_IMAGE_REF" \
    --arg producer "$DIENE_SUBJECT_PRODUCER_WORKFLOW_REF" --arg attestation "${DIENE_ARTIFACT_ATTESTATION_DIGEST:-}" \
    --arg closure "${DIENE_CLOSURE_DIGEST:-}" --arg closureSignature "${DIENE_CLOSURE_SIGNATURE_BUNDLE_DIGEST:-}" \
    --arg closureRoot "${DIENE_CLOSURE_TRUST_ROOT_DIGEST:-}" --arg allocationKey "$(diene_allocation_key)" \
    --arg generationKey "$(diene_generation_key)" --arg substrateName "$DRIVER_SUBSTRATE_NAME" \
    --arg receiptId "$(diene_receipt_id)" --arg clusterId "$DIENE_NSC_CLUSTER_ID" \
    --arg garden "$DIENE_GARDEN_LOCK_DIGEST" --arg journeyDigest "$journey_digest" \
    --arg environmentDigest "$environment_digest" --arg nscVersion "$DIENE_NSC_VERSION" \
    --arg sourceDigest "$DIENE_SOURCE_ARCHIVE_DIGEST" \
    --arg subjectDigest "$(diene_file_digest "$DIENE_ARTIFACT_SUBJECT")" \
    --arg verdict "$verdict" --arg reason "$reason" --arg teardownOutcome "$teardown_outcome" \
    --arg absence "$absence" --argjson journeys "$journeys" --argjson coverage "$coverage" \
    --argjson transitions "$transitions" --argjson debt "$debt" \
    --argjson setup "$DRIVER_SETUP_SECONDS" --argjson substrate "$DRIVER_SUBSTRATE_SECONDS" \
    --argjson readinessSeconds "$DRIVER_READINESS_SECONDS" --argjson journeysSeconds "$DRIVER_JOURNEY_SECONDS" \
    --argjson teardown "$DRIVER_TEARDOWN_SECONDS" --slurpfile readiness "$DRIVER_READINESS" \
    --slurpfile preflight "$preflight" --slurpfile probes "$probes" --slurpfile checkpoint "$DRIVER_CHECKPOINT" '
    {apiVersion:"diene.atomi.cloud/ci-environment-report/v1",repositoryRevision:$revision,
     workflow:{runId:$runId,runAttempt:$runAttempt,workflowRef:$workflowRef},lane:$lane,profile:$profile,
     buildMode:$buildMode,
     subject:({artifactDigest:$artifact,imageRef:$imageRef,producerWorkflowRef:$producer}
       + (if $attestation == "" then {} else {provenanceAttestationDigest:$attestation} end)
       + (if $closure == "" then {} else {closureDigest:$closure} end)
       + (if $closureSignature == "" then {} else {closureSignatureBundleDigest:$closureSignature} end)
       + (if $closureRoot == "" then {} else {closureTrustRootDigest:$closureRoot} end)),
     instance:{allocationKey:$allocationKey,generationKey:$generationKey,substrateName:$substrateName,
       clusterId:$clusterId,osId:$preflight[0].os.id,osVersion:$preflight[0].os.version,
       k3sVersion:$preflight[0].k3s.version,kubernetesVersion:$preflight[0].k3s.kubernetesVersion,
       nodeCount:$preflight[0].k3s.nodeCount,capacity:$preflight[0].k3s.capacity},receiptId:$receiptId,
     tooling:({gardenLockDigest:$garden,journeyManifestDigest:$journeyDigest,nscVersion:$nscVersion,
       sourceArchiveDigest:$sourceDigest,artifactSubjectDigest:$subjectDigest}
       + (if $environmentDigest == "" then {} else {environmentLockDigest:$environmentDigest} end)),
     readiness:($readiness[0] // null),journeys:$journeys,coverage:$coverage,
     evidence:{leakageScan:{outcome:"Pass",reasonCode:"ScanPendingFinalisation",encodings:[],scannedPaths:[]},
       egressCanary:{outcome:(if ($probes[0] | length) >= 6 then "Pass" else "Fail" end),
         reasonCode:(if ($probes[0] | length) >= 6 then "HostAndPodNegativeProbesPassed" else "ProbeEvidenceIncomplete" end),
         mode:(if $lane == "absol" or $lane == "fleet-independence" then "closure-denied-network" else "allowlist" end),
         profileId:(if $lane == "absol" then "absol-hermetic-v1" elif $lane == "fleet-independence" then "fleet-independence-v1"
           elif $lane == "ditto-target-pull" then "ditto-target-pull-v1" else "ditto-build-local-v1" end),
         enforcement:"interim-in-guest-iptables-nft",
         platformStatus:"platform per-instance policy pending (support ask #4)",hostileProbes:($probes[0] // [])},
       shipment:{outcome:"Unavailable",reasonCode:"CollectedByOuterOrchestrator"}},
     teardown:{outcome:$teardownOutcome,reasonCode:(if $teardownOutcome == "Pass" then "ExactReceiptDestroyed" else "CleanupDebt" end),
       transitions:$transitions,finalizerWaitSeconds:0,debt:$debt,absenceProof:$absence},
     checkpointChain:$checkpoint[0],
     timings:{setupSeconds:$setup,substrateSeconds:$substrate,readinessSeconds:$readinessSeconds,
       journeysSeconds:$journeysSeconds,teardownSeconds:$teardown},outcome:$verdict}
     + (if $reason == "" then {} else {reasonCode:$reason} end)' |
    diene_write_json "$DRIVER_RUNTIME_DIR/core-report.driver.json"
  [[ -f $endpoint ]] || true
}

driver_package() {
  local exit_code=${1:?exit code required} outcome reason
  outcome=Pass
  reason=DriverCompleted
  if ((exit_code != 0)); then
    outcome=Fail
    reason=${2:-DriverFailed}
  fi
  jq -n --arg outcome "$outcome" --arg reason "$reason" --argjson exitCode "$exit_code" \
    '{outcome:$outcome,reasonCode:$reason,exitCode:$exitCode}' |
    diene_write_json "$DRIVER_RUNTIME_DIR/driver-status.json"
  install -m 0600 "$DRIVER_RECEIPT" "$DRIVER_RUNTIME_DIR/ci-receipt.json"
  install -d -m 0700 "$DRIVER_STATE/out"
  tar -cf "$DRIVER_STATE/out/proof.tar" -C "$DRIVER_RUNTIME_DIR/.." evidence
  chmod 0600 "$DRIVER_STATE/out/proof.tar"
  (cd "$DRIVER_STATE/out" && sha256sum proof.tar >proof.sha256)
  chmod 0600 "$DRIVER_STATE/out/proof.sha256"
}

driver_finalize() {
  local prior=${1:-0}
  ((DRIVER_FINALIZED == 0)) || return "$prior"
  DRIVER_FINALIZED=1
  local reason='' result=$prior
  if [[ -s $DIENE_REASON_FILE ]]; then
    IFS=$'\t' read -r reason _ <"$DIENE_REASON_FILE" || true
  fi
  driver_cleanup || {
    ((result != 0)) || result=$DIENE_REASON_EXIT
    [[ -n $reason ]] || reason=CleanupDebt
  }
  local evidence_digest
  evidence_digest=$(phase_digest driver "$DIENE_NSC_CLUSTER_ID" "${reason:-Pass}")
  if ((result == 0)); then
    diene_checkpoint_append "$DRIVER_CHECKPOINT" final-clean-pass Pass "$evidence_digest" false
    diene_checkpoint_seal "$DRIVER_CHECKPOINT" true
    driver_emit_report Pass ''
  else
    diene_checkpoint_append "$DRIVER_CHECKPOINT" driver-failure Fail "$evidence_digest" false
    diene_checkpoint_seal "$DRIVER_CHECKPOINT" false
    driver_emit_report Fail "${reason:-DriverFailed}"
  fi
  driver_package "$result" "${reason:-DriverFailed}"
  return "$result"
}

driver_on_exit() {
  local prior=$?
  trap - EXIT TERM INT HUP
  local rc=0
  driver_finalize "$prior" || rc=$?
  exit "$rc"
}

driver_on_signal() {
  local rc=${1:?signal status required}
  diene_warn DriverCancelled 'signal received by on-instance driver'
  printf 'DriverCancelled\tsignal received\n' >"$DIENE_REASON_FILE"
  exit "$rc"
}

driver_core() {
  DRIVER_STATE=${1:?fixed driver state directory required}
  diene_load_remote_inputs "$DRIVER_STATE"
  if [[ $DIENE_LANE == ditto-vendor ]]; then
    exec "$script_dir/environment-vendor-run.sh" driver "$DRIVER_STATE"
  fi
  diene_validate_inputs
  for command in jq sha256sum timeout tar; do diene_require_command "$command"; done
  diene_require_command "${DIENE_PLS_BIN:-pls}"
  diene_require_command "${DIENE_SCHEMA_VALIDATOR_BIN:-check-jsonschema}"
  DRIVER_RUNTIME_DIR="$DRIVER_STATE/evidence"
  install -d -m 0700 "$DRIVER_RUNTIME_DIR"
  export DIENE_EVIDENCE_STAGING="$DRIVER_RUNTIME_DIR/staging"
  install -d -m 0700 "$DIENE_EVIDENCE_STAGING"
  for surface in stdout stderr argv environ; do
    : >"$DIENE_EVIDENCE_STAGING/$surface"
    chmod 0600 "$DIENE_EVIDENCE_STAGING/$surface"
  done
  printf '%q ' "$0" "$@" >"$DIENE_EVIDENCE_STAGING/argv"
  printf '\n' >>"$DIENE_EVIDENCE_STAGING/argv"
  env | grep -v '^DIENE_LEAK_CANARY=' | LC_ALL=C sort >"$DIENE_EVIDENCE_STAGING/environ"
  export DIENE_REASON_FILE="$DRIVER_RUNTIME_DIR/reason"
  : >"$DIENE_REASON_FILE"
  DRIVER_RESULTS="$DRIVER_RUNTIME_DIR/journeys.jsonl"
  DRIVER_COVERAGE="$DRIVER_RUNTIME_DIR/coverage.jsonl"
  DRIVER_READINESS="$DRIVER_RUNTIME_DIR/readiness.json"
  : >"$DRIVER_RESULTS"
  : >"$DRIVER_COVERAGE"
  : >"$DRIVER_READINESS"
  DRIVER_RECEIPT="$DRIVER_STATE/receipts/exact.json"
  export DIENE_RECEIPT_DIR="$DRIVER_STATE/receipts"
  diene_validate_receipt_owner "$DRIVER_RECEIPT" "$DIENE_NSC_CLUSTER_ID"
  DRIVER_CHECKPOINT="$DRIVER_RUNTIME_DIR/checkpoint-chain.json"
  local input_digest
  input_digest=$(diene_sha256_text \
    "$GITHUB_SHA|$DIENE_SOURCE_ARCHIVE_DIGEST|$DIENE_GARDEN_LOCK_DIGEST|$DIENE_ARTIFACT_DIGEST|$(diene_file_digest "$DIENE_EGRESS_CONTRACT")")
  diene_checkpoint_init "$DRIVER_CHECKPOINT" "$input_digest"
  jq -n --arg clusterId "$DIENE_NSC_CLUSTER_ID" '
    {outcome:"Fail",reasonCode:"PreflightNotCompleted",clusterId:$clusterId,
     os:{id:null,version:null,uid:0},
     k3s:{version:null,kubernetesVersion:null,nodeCount:null,capacity:null},
     network:{podCidrs:[],serviceCidrs:[],ipv6Disabled:false,namespaceIngress:false,publicBinding:false},
     storage:{defaultClass:null},policyBackend:{mechanism:"iptables",backend:"nf_tables",version:null},
     cacheAttached:false,platformStatus:"platform per-instance policy pending (support ask #4)"}' |
    diene_write_json "$DRIVER_RUNTIME_DIR/preflight.json"
  printf '[]\n' | diene_write_json "$DRIVER_RUNTIME_DIR/hostile-probes.json"
  DRIVER_STARTED=$SECONDS
  trap driver_on_exit EXIT
  trap 'driver_on_signal 143' TERM HUP
  trap 'driver_on_signal 130' INT

  local preflight="$DRIVER_RUNTIME_DIR/preflight.json"
  export DIENE_PREFLIGHT_EVIDENCE=$preflight
  "$script_dir/environment-runner-preflight.sh" --output "$preflight"
  diene_checkpoint_append "$DRIVER_CHECKPOINT" instance-preflight Pass "$(diene_file_digest "$preflight")" false

  local manifest=$DIENE_JOURNEY_MANIFEST
  [[ -f $manifest ]] || diene_die InputContractInvalid 'journey manifest missing'
  diene_schema_validate diene-journeys-v1.schema.json "$manifest" 'journey manifest'
  jq -e '[.journeys[].id] | length == (unique | length)' "$manifest" >/dev/null ||
    diene_die InputContractInvalid 'journey IDs must be globally unique'

  local closure_verifier='' pull_proof=''
  if [[ $DIENE_LANE == absol ]]; then
    closure_verifier=$(diene_require_closure_verifier)
    "$closure_verifier" verify --digest "$DIENE_CLOSURE_DIGEST" --bundle "$DIENE_CLOSURE_BUNDLE_REF" \
      --signature-digest "$DIENE_CLOSURE_SIGNATURE_BUNDLE_DIGEST" \
      --trust-root-digest "$DIENE_CLOSURE_TRUST_ROOT_DIGEST" ||
      diene_die ClosureAttestationInterfaceUnavailable 'signed closure verification failed'
    "${DIENE_PLS_BIN:-pls}" closure import "$DIENE_CLOSURE_BUNDLE_REF"
  elif [[ $DIENE_LANE == ditto-target-pull ]]; then
    pull_proof=$(diene_require_pull_proof)
  fi

  local resolved="$DRIVER_RUNTIME_DIR/egress-resolved.json"
  local policy="$DRIVER_RUNTIME_DIR/policy.json" l7="$DRIVER_RUNTIME_DIR/l7-egress.json"
  diene_resolve_egress_contract "$DIENE_EGRESS_CONTRACT" "$resolved"
  diene_preflow_start
  diene_apply_interim_policy "$resolved" "$policy" "$l7"
  DRIVER_POLICY_APPLIED=1
  diene_verify_hostile_egress "$DRIVER_RUNTIME_DIR/hostile-probes.json"
  diene_receipt_patch "$DRIVER_RECEIPT" \
    '.namespace.policy.applied = true | .namespace.policy.hostileProbes = "Pass"'
  diene_checkpoint_append "$DRIVER_CHECKPOINT" egress-policy Pass "$(diene_file_digest "$policy")" false

  if [[ $DIENE_LANE == absol ]]; then
    "${DIENE_PLS_BIN:-pls}" closure preflight --denied-network
    "$closure_verifier" exact-set --digest "$DIENE_CLOSURE_DIGEST" --network-denied ||
      diene_die ClosureAttestationInterfaceUnavailable 'closure exact-set equality failed under denial'
  fi
  DRIVER_SETUP_SECONDS=$((SECONDS - DRIVER_STARTED))

  local substrate_started=$SECONDS profile build_mode
  profile=$(diene_runtime_profile "$DIENE_LANE")
  build_mode=$(diene_build_mode "$DIENE_LANE")
  "${DIENE_PLS_BIN:-pls}" env up --profile "$profile" --build-mode "$build_mode" \
    --artifact "$DIENE_ARTIFACT_DIGEST"
  DRIVER_SUBSTRATE_SECONDS=$((SECONDS - substrate_started))
  DRIVER_RUNTIME_FILE=$(diene_discover_runtime "$profile" "$(diene_allocation_key)" "$(diene_generation_key)")
  jq -e --arg digest "$DIENE_ARTIFACT_DIGEST" '.artifact.digest == $digest' "$DRIVER_RUNTIME_FILE" >/dev/null ||
    diene_die UntrustedSubject 'Garden runtime record carries another artifact digest'
  DRIVER_SUBSTRATE_NAME=$(jq -r '.substrate.name' "$DRIVER_RUNTIME_FILE")
  # shellcheck disable=SC2016
  diene_receipt_patch "$DRIVER_RECEIPT" '.runtimeFile = $path | .cleanup.reasonCode = "RuntimeBound"' \
    --arg path "$DRIVER_RUNTIME_FILE"
  export DIENE_GARDEN_RUNTIME_FILE=$DRIVER_RUNTIME_FILE
  diene_checkpoint_append "$DRIVER_CHECKPOINT" render-apply Pass \
    "$(phase_digest render "$DRIVER_SUBSTRATE_NAME" "$DRIVER_SUBSTRATE_SECONDS")" false

  local readiness_started=$SECONDS
  "${DIENE_PLS_BIN:-pls}" env doctor --profile "$profile" --json >"$DRIVER_READINESS" ||
    diene_die ReadinessEvidenceUnavailable 'pls env doctor emitted no readiness evidence'
  diene_schema_validate diene-readiness-v1.schema.json "$DRIVER_READINESS" 'readiness evidence'
  jq -e --arg profile "$profile" '
    .profile == $profile and .outcome == "Pass" and
    ([.readiness[] | select(.required == true) | .outcome] | length > 0 and all(. == "Pass")) and
    any(.readiness[]; .id == "EnvironmentReady" and .outcome == "Pass") and
    ([.readiness[] | select(.id == "AllocationReady" or .id == "CastformProdSafetyReady" or .id == "CallbackReady") | .outcome]
      | all(. == "NotRequired"))
  ' "$DRIVER_READINESS" >/dev/null || diene_die EnvironmentNotReady '17-leaf readiness DAG did not converge'
  DRIVER_READINESS_SECONDS=$((SECONDS - readiness_started))
  diene_checkpoint_append "$DRIVER_CHECKPOINT" environment-ready Pass \
    "$(diene_file_digest "$DRIVER_READINESS")" false

  if [[ $DIENE_LANE == ditto-target-pull ]]; then
    for proof in real-pull evict-repull sibling-denial pull-secret-ownership credential-removal; do
      "$pull_proof" "$proof" --digest "$DIENE_ARTIFACT_DIGEST" --receipt "$(diene_receipt_id)" ||
        diene_die RequiredCoverageUnavailable "target-pull did not prove $proof"
    done
  fi

  local journeys_started=$SECONDS selection="$DRIVER_RUNTIME_DIR/selection.jsonl" fixture=${DIENE_FIXTURE_ID:-}
  jq -c --arg lane "$DIENE_LANE" --arg profile "$profile" --arg mode "$build_mode" --arg fixture "$fixture" '
    .journeys[] | select(any(.appliesTo[];
      .lane == $lane and .profile == $profile and .buildMode == $mode and
      ((.fixtureId // "") == $fixture)))
  ' "$manifest" >"$selection"
  local required_failure=0 entry_file="$DRIVER_RUNTIME_DIR/journey.json"
  while IFS= read -r entry; do
    printf '%s\n' "$entry" >"$entry_file"
    local journey_id pack_id pack_digest journey_required pack_path actual outcome reason started
    journey_id=$(jq -er '.id' "$entry_file")
    pack_id=$(jq -er '.fixturePack.id' "$entry_file")
    pack_digest=$(jq -er '.fixturePack.digest' "$entry_file")
    journey_required=$(jq -r '.required' "$entry_file")
    pack_path=".diene/ci/fixtures/$pack_id/manifest.yaml"
    started=$SECONDS
    if [[ ! -f $pack_path ]]; then
      outcome=Unavailable
      [[ $journey_required != true ]] || { outcome=Fail; required_failure=1; }
      jq -nc --arg id "$journey_id" --arg outcome "$outcome" --argjson required "$journey_required" \
        --argjson duration "$((SECONDS - started))" \
        '{id:$id,outcome:$outcome,reasonCode:"FixtureUnavailable",required:$required,durationSeconds:$duration}' \
        >>"$DRIVER_RESULTS"
      continue
    fi
    actual=$(diene_file_digest "$pack_path")
    if [[ $actual != "$pack_digest" ]]; then
      required_failure=1
      jq -nc --arg id "$journey_id" --argjson required "$journey_required" --arg digest "$actual" \
        --argjson duration "$((SECONDS - started))" \
        '{id:$id,outcome:"Fail",reasonCode:"FixturePackDigestMismatch",required:$required,
          durationSeconds:$duration,fixturePackDigest:$digest}' >>"$DRIVER_RESULTS"
      continue
    fi
    outcome=Pass
    reason=AssertionsSatisfied
    if ! diene_run_argv "$entry_file" . setup; then outcome=Fail; reason=SetupFailed; fi
    if [[ $outcome == Pass ]] && ! diene_run_argv "$entry_file" . probe; then outcome=Fail; reason=ProbeFailed; fi
    if ! diene_run_argv "$entry_file" . cleanup; then outcome=Fail; reason=CleanupFailed; required_failure=1; fi
    [[ $outcome == Pass || $journey_required != true ]] || required_failure=1
    jq -nc --arg id "$journey_id" --arg outcome "$outcome" --arg reason "$reason" \
      --argjson required "$journey_required" --argjson duration "$((SECONDS - started))" \
      --arg digest "$pack_digest" \
      '{id:$id,outcome:$outcome,reasonCode:$reason,required:$required,durationSeconds:$duration,
        fixturePackDigest:$digest}' >>"$DRIVER_RESULTS"
  done <"$selection"
  [[ -s $DRIVER_RESULTS ]] || jq -nc \
    '{id:"NoDeclaration",outcome:"NotApplicable",reasonCode:"NoDeclaration",required:false,durationSeconds:0}' \
    >"$DRIVER_RESULTS"
  DRIVER_JOURNEY_SECONDS=$((SECONDS - journeys_started))
  ((required_failure == 0)) || diene_die JourneyFailed 'a required journey did not pass'
  diene_checkpoint_append "$DRIVER_CHECKPOINT" journeys Pass \
    "$(phase_digest journeys "$DIENE_LANE" "$DRIVER_JOURNEY_SECONDS")" false

  diene_verify_endpoint_law "$DRIVER_RUNTIME_DIR/endpoint-law.json"
}

case ${1:-orchestrate} in
  --validate-inputs)
    diene_validate_inputs
    ;;
  orchestrate)
    shift || true
    orchestrate "$@"
    ;;
  cleanup)
    shift
    orchestrator_cleanup_command "$@"
    ;;
  lifecycle)
    shift
    orchestrator_verify_lifecycle "$@"
    ;;
  driver)
    shift
    driver_core "$@"
    ;;
  *) diene_die InputContractInvalid "unknown environment-k3d mode ${1:-}" ;;
esac
