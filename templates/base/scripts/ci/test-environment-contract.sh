#!/usr/bin/env bash
# Fully local proof of the diene-ci-k3d/v1 compatibility contract. The fake
# Namespace CLI implements only the measured nsc v0.0.532 lifecycle surface;
# every other verb or argument is a test failure by construction.
# Test scenarios deliberately reuse environment names in isolated subshells.
# shellcheck disable=SC2030,SC2031
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
template_root=$(cd -- "$script_dir/../.." && pwd)
scratch=$(mktemp -d)
trap 'rm -r -- "$scratch"' EXIT

passed=0
fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}
ok() {
  passed=$((passed + 1))
  printf '  ok %s\n' "$*"
}
expect_refusal() {
  local reason=${1:?reason required}
  shift
  if "$@" >"$scratch/stdout" 2>"$scratch/stderr"; then
    fail "expected $reason refusal but the command succeeded"
  fi
  grep -Fq -- "$reason" "$scratch/stderr" || {
    sed -n '1,160p' "$scratch/stderr" >&2
    fail "missing $reason evidence"
  }
  ok "refuses $reason"
}
expect_precreate_refusal() {
  local reason=${1:?reason required}
  shift
  : >"$FAKE_NSC_LOG"
  if (cd -- "$work" && "$@") >"$scratch/stdout" 2>"$scratch/stderr"; then
    fail "expected pre-create $reason refusal but the command succeeded"
  fi
  grep -Fq -- "$reason" "$scratch/stderr" || {
    sed -n '1,160p' "$scratch/stderr" >&2
    fail "missing pre-create $reason evidence"
  }
  ! grep -Eq '^create( |$)' "$FAKE_NSC_LOG" ||
    fail "$reason was reached only after fake nsc create"
  ok "$reason refuses before nsc create"
}

for command in jq check-jsonschema sha256sum tar grep sed awk find timeout rg base64; do
  command -v "$command" >/dev/null 2>&1 || fail "$command is required for the contract suite"
done

SOURCE_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
ARTIFACT_DIGEST=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
ATTESTATION_DIGEST=sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
CLOSURE_DIGEST=sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
CLOSURE_SIGNATURE_DIGEST=sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
CLOSURE_ROOT_DIGEST=sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
GARDEN_DIGEST=sha256:1111111111111111111111111111111111111111111111111111111111111111
CANARY_IMAGE=registry.example.test/diene-egress-canary@sha256:2222222222222222222222222222222222222222222222222222222222222222
WORKFLOW_REF="AtomiCloud/example/.github/workflows/environment-k3d.yaml@$SOURCE_SHA"

work=$scratch/work
install -d -m 0700 "$work/scripts/ci" "$work/schemas" \
  "$work/.diene/ci/fixtures/demo" "$work/.diene/ci/fixtures/bootstrap-fleet-independence-v1"
cp -R "$template_root/schemas/ci" "$work/schemas/"
cp "$script_dir"/environment-*.sh "$work/scripts/ci/"
chmod 0755 "$work/scripts/ci"/*.sh

cat >"$work/.diene/ci/artifact-producer.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat >"$work/.diene/ci/l7-enforcer" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%q ' "$@" >>"${FAKE_L7_LOG:-/dev/null}"
printf '\n' >>"${FAKE_L7_LOG:-/dev/null}"
command=${1:-}
shift || true
case $command in
  apply)
    evidence=
    while (($#)); do
      case $1 in
        --profile | --receipt | --contract) shift 2 ;;
        --evidence) evidence=${2:?}; shift 2 ;;
        *) exit 127 ;;
      esac
    done
    [[ -n $evidence ]] || exit 127
    jq -n --argjson complete "${FAKE_L7_COMPLETE:-true}" \
      '{outcome:"Pass",dnsBound:true,sniBound:true,methodsBound:true,defaultDenied:$complete}' >"$evidence"
    ;;
  remove)
    [[ ${1:-} == --profile && ${3:-} == --receipt && $# -eq 4 ]] || exit 127
    ;;
  *) exit 127 ;;
esac
SH
cat >"$work/.diene/ci/egress-probe" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%q ' "$@" >>"${FAKE_PROBE_LOG:-/dev/null}"
printf '\n' >>"${FAKE_PROBE_LOG:-/dev/null}"
scope=
while (($#)); do
  case $1 in
    --scope) scope=${2:?}; shift 2 ;;
    --profile | --cluster-id | --image) shift 2 ;;
    *) exit 127 ;;
  esac
done
[[ -n $scope && $scope != "${FAKE_PROBE_FAIL_SCOPE:-}" ]]
SH
cat >"$work/.diene/ci/vendor-broker" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%q ' "$@" >>"${FAKE_BROKER_LOG:-/dev/null}"
printf '\n' >>"${FAKE_BROKER_LOG:-/dev/null}"
command=${1:-}
shift || true
[[ $command != "${FAKE_BROKER_FAIL_COMMAND:-}" ]] || exit 69
case $command in
  issue)
    output=
    evidence=
    while (($#)); do
      case $1 in
        --action) shift 2 ;;
        --output) output=${2:?}; shift 2 ;;
        --evidence) evidence=${2:?}; shift 2 ;;
        *) exit 127 ;;
      esac
    done
    [[ -n $output && -n $evidence ]] || exit 127
    printf '%s\n' 'masked-contract-credential' >"$output"
    chmod 0600 "$output"
    jq -n '{outcome:"Pass",masked:true,issuedAfterReadiness:true}' >"$evidence"
    ;;
  revoke)
    while (($#)); do
      case $1 in
        --action | --credential-file | --absence-proven) shift 2 ;;
        *) exit 127 ;;
      esac
    done
    ;;
  *) exit 127 ;;
esac
SH
chmod 0755 "$work/.diene/ci/artifact-producer.sh" "$work/.diene/ci/l7-enforcer" \
  "$work/.diene/ci/egress-probe" "$work/.diene/ci/vendor-broker"

printf '%s\n' '{"apiVersion":"diene.atomi.cloud/ci-fixture/v1","id":"demo"}' \
  >"$work/.diene/ci/fixtures/demo/manifest.yaml"
printf '%s\n' '{"apiVersion":"diene.atomi.cloud/ci-fixture/v1","id":"bootstrap-fleet-independence-v1"}' \
  >"$work/.diene/ci/fixtures/bootstrap-fleet-independence-v1/manifest.yaml"
demo_pack_digest="sha256:$(sha256sum "$work/.diene/ci/fixtures/demo/manifest.yaml" | awk '{print $1}')"
fleet_pack_digest="sha256:$(sha256sum "$work/.diene/ci/fixtures/bootstrap-fleet-independence-v1/manifest.yaml" | awk '{print $1}')"
jq -n --arg demo "$demo_pack_digest" --arg fleet "$fleet_pack_digest" '
  def journey($id;$pack;$applies):
    {id:$id,componentClass:"K1",appliesTo:$applies,required:true,
     fixturePack:{id:$pack,version:"1.0.0",digest:(if $pack == "demo" then $demo else $fleet end)},
     setup:["/bin/true"],probe:["/bin/true"],cleanup:["/bin/true"],workingDirectory:".",
     timeoutSeconds:60,poll:{intervalSeconds:1,attempts:3},readinessLeaves:["EnvironmentReady"],
     assertions:["fixture responds"],safeReportFields:["id"]};
  {apiVersion:"diene.atomi.cloud/ci-journeys/v1",journeys:[
    journey("core-demo";"demo";[
      {lane:"ditto-build-local",profile:"ditto",buildMode:"build-local"},
      {lane:"ditto-target-pull",profile:"ditto",buildMode:"target-pull"},
      {lane:"absol",profile:"absol",buildMode:"build-local"}]),
    journey("fleet-demo";"bootstrap-fleet-independence-v1";[
      {lane:"fleet-independence",profile:"ditto",buildMode:"build-local",
       fixtureId:"bootstrap-fleet-independence-v1"}])
  ]}' >"$work/.diene/ci/journeys.v1.yaml"

jq -n --arg digest "$demo_pack_digest" '
  {apiVersion:"diene.atomi.cloud/ci-vendors/v1",actions:[{
    componentClass:"K9",actionId:"demo-vendor",permissionRule:"ditto-vendor-demo",
    profile:"ditto",buildMode:"build-local",required:false,
    fixturePack:{id:"demo",version:"1.0.0",digest:$digest},account:"sandbox-demo",
    endpoint:"https://vendor.example.test",credentialEnv:"DIENE_VENDOR_CREDENTIAL",
    credentialWriter:"github-environment",
    egress:[{dns:"vendor.example.test",sni:"vendor.example.test",port:443,methods:["GET","POST","DELETE"]}],
    setup:["/bin/true"],probe:["/bin/true"],cleanup:["/bin/true"],absence:["/bin/true"],
    timeoutSeconds:60,retryAttempts:0,callbackCompletion:"poll"}]}' \
  >"$work/.diene/ci/vendors.v1.yaml"

cat >"$work/.diene/ci/environment-lock.v1.json" <<'JSON'
{
  "apiVersion":"diene.atomi.cloud/environment-lock/v1",
  "profiles":{
    "lapras":{"substrate":"k3d"},"ditto":{"substrate":"k3d"},
    "rotom":{"substrate":"k3d"},"absol":{"substrate":"k3d"},
    "eevee":{"substrate":"entei-vcluster"},"castform":{"substrate":"entei-vcluster"}
  },
  "previewManifest":{
    "schemaVersion":"preview-manifest/v1",
    "schemaDigest":"sha256:3333333333333333333333333333333333333333333333333333333333333333",
    "wordListVersion":"v1"
  },
  "operator":{"kind":"operator","version":"1.0.0"}
}
JSON

source_archive=$scratch/source.tar
make_source_archive() {
  tar -cf "$source_archive" -C "$work" scripts schemas .diene
  chmod 0600 "$source_archive"
}
make_source_archive

write_subject() {
  local target=${1:?subject target required}
  local run_id=${2:?run id required}
  local run_attempt=${3:?run attempt required}
  jq -n --arg sha "$SOURCE_SHA" --arg digest "$ARTIFACT_DIGEST" \
    --arg workflow "$WORKFLOW_REF" --arg runId "$run_id" --arg runAttempt "$run_attempt" \
    --arg attestation "$ATTESTATION_DIGEST" --arg closure "$CLOSURE_DIGEST" \
    --arg closureSignature "$CLOSURE_SIGNATURE_DIGEST" --arg closureRoot "$CLOSURE_ROOT_DIGEST" '
    {apiVersion:"diene.atomi.cloud/ci-artifact-subject/v1",sourceSha:$sha,
     artifact:{imageRef:("ghcr.io/atomicloud/example@"+$digest),digest:$digest,registry:"ghcr.io",private:true,
       producer:{workflowRef:$workflow,runId:$runId,runAttempt:$runAttempt}},
     provenance:{predicateType:"https://slsa.dev/provenance/v1",
       provenanceRef:("oci://ghcr.io/atomicloud/example/provenance/"+$sha),
       attestationDigest:$attestation,workflowRef:$workflow,runId:$runId,runAttempt:$runAttempt,
       pullIdentity:"AtomiCloud/example-selected-package-reader"},
     closure:{bundleRef:("oci://ghcr.io/atomicloud/example/closure/"+$sha),digest:$closure,
       signatureBundleDigest:$closureSignature,trustRootDigest:$closureRoot}}' >"$target"
  chmod 0600 "$target"
}

# The fake guest does not bypass the outer contract. It produces the fixed
# archive the real orchestrator downloads, and the real outer code validates,
# augments, leakage-scans, schemas, destroys, proves absence, and seals it.
fake_guest=$scratch/fake-guest
cat >"$fake_guest" <<'GUEST'
#!/usr/bin/env bash
set -euo pipefail
state=${1:?guest state required}
cluster_id=${2:?cluster id required}
scenario=${FAKE_NSC_SCENARIO:-happy}
install -d -m 0700 "$state/source" "$state/evidence" "$state/out"
tar -xf "$state/source.tar" -C "$state/source"
inputs=$state/inputs.json
receipt=$state/receipt.json
evidence=$state/evidence

# shellcheck disable=SC1091
source "${TEMPLATE_SCRIPT_DIR:?}/environment-lib.sh"
input_digest=$(diene_sha256_text "$(jq -cS . "$inputs")")
diene_checkpoint_init "$evidence/checkpoint-chain.json" "$input_digest"
diene_checkpoint_append "$evidence/checkpoint-chain.json" final-clean-pass Pass \
  "$(diene_sha256_text "$cluster_id|final-clean-pass")" false
diene_checkpoint_seal "$evidence/checkpoint-chain.json" true
if [[ $scenario == checkpoint-broken ]]; then
  jq '.checkpoints[0].predecessorDigest = "sha256:9999999999999999999999999999999999999999999999999999999999999999"' \
    "$evidence/checkpoint-chain.json" >"$evidence/checkpoint-chain.json.tmp"
  mv "$evidence/checkpoint-chain.json.tmp" "$evidence/checkpoint-chain.json"
fi

jq -n --arg cluster "$cluster_id" '
  {outcome:"Pass",reasonCode:"NamespaceWolfiBuiltInK3sReady",clusterId:$cluster,
   identitySource:"cidfile-metadata-exact-id-ssh",os:{id:"wolfi",version:"rolling",uid:0},
   k3s:{version:"v1.33.1+k3s1",kubernetesVersion:"v1.33.1+k3s1",nodeCount:1,
        capacity:{cpu:"16",memory:"32Gi"}},
   network:{podCidrs:["10.142.0.0/16"],serviceCidrs:["10.143.0.0/16"],ipv6Disabled:false,
            namespaceIngress:false,publicBinding:false},storage:{defaultClass:"local-path"},
   policyBackend:{mechanism:"iptables",backend:"nf_tables",version:"iptables v1.8.13 (nf_tables)"},
   cacheAttached:false,platformStatus:"platform per-instance policy pending (support ask #4)"}' \
  >"$evidence/preflight.json"

jq -n '[
  {id:"preexisting-flow-transition-denial",outcome:"Pass",reasonCode:"NoGrandfatheredExternalFlow",required:true},
  {id:"host-metadata-denial",outcome:"Pass",reasonCode:"ConnectionRefused",required:true},
  {id:"host-arbitrary-https-denial",outcome:"Pass",reasonCode:"ConnectionRefused",required:true},
  {id:"pod-metadata-denial",outcome:"Pass",reasonCode:"ForwardRefused",required:true},
  {id:"pod-arbitrary-https-denial",outcome:"Pass",reasonCode:"ForwardRefused",required:true},
  {id:"pod-dns-denial",outcome:"Pass",reasonCode:"ForwardRefused",required:true}
]' >"$evidence/hostile-probes.json"

lane=$(jq -r '.lane' "$inputs")
profile=ditto
mode=build-local
profile_id=ditto-build-local-v1
case $lane in
  ditto-target-pull) mode=target-pull; profile_id=ditto-target-pull-v1 ;;
  ditto-vendor) profile_id=ditto-vendor-v1 ;;
  absol) profile=absol; profile_id=absol-hermetic-v1 ;;
  fleet-independence) profile_id=fleet-independence-v1 ;;
esac
allocation=$(jq -r '.owner.allocationKey' "$receipt")
generation=$(jq -r '.owner.generationKey' "$receipt")
receipt_id=$(jq -r '.owner.receiptId' "$receipt")
journey_digest="sha256:$(sha256sum "$state/source/.diene/ci/journeys.v1.yaml" | awk '{print $1}')"
vendor_digest="sha256:$(sha256sum "$state/source/.diene/ci/vendors.v1.yaml" | awk '{print $1}')"

jq -n --arg profile "$profile" --arg allocation "$allocation" '
  def leaf($id;$required):
    if $required then {id:$id,outcome:"Pass",required:true,reasonCode:"Converged",
      sourceUid:("uid-"+$id),observedGeneration:1,allocationKey:$allocation,
      transitionTime:"2026-07-31T00:00:00Z"}
    else {id:$id,outcome:"NotRequired",required:false,reasonCode:"NotApplicableToLane"} end;
  {apiVersion:"diene-readiness/v1",profile:$profile,aggregate:"EnvironmentReady",outcome:"Pass",
   readiness:[leaf("SubstrateReady";true),leaf("SeedReady";true),leaf("StoreReady";true),
    leaf("ExternalSecretsReady";true),leaf("DependenciesReady";true),leaf("PVCsReady";true),
    leaf("MigrationsReady";true),leaf("FixturesReady";true),leaf("LogtoReady";true),
    leaf("ArtifactPullReady";true),leaf("ApplicationWorkloadsReady";true),
    leaf("ExposurePrerequisitesReady";true),leaf("ExposureReady";true),leaf("EnvironmentReady";true),
    leaf("AllocationReady";false),leaf("CastformProdSafetyReady";false),leaf("CallbackReady";false)]}' \
  >"$evidence/readiness.json"

report_outcome=Pass
report_reason=''
driver_exit=0
if [[ $scenario == driver-fail ]]; then
  report_outcome=Fail
  report_reason=JourneyFailed
  driver_exit=64
fi

if [[ $lane == ditto-vendor ]]; then
  required=$(jq -r --arg id "$(jq -r '.selectors.actionId' "$inputs")" \
    '.actions[] | select(.actionId == $id) | .required' "$state/source/.diene/ci/vendors.v1.yaml")
  vendor_outcome=Pass
  vendor_reason=AssertionsSatisfied
  if [[ $scenario == vendor-unavailable ]]; then
    vendor_outcome=Unavailable
    vendor_reason=ProviderUnavailable
    report_outcome=Unavailable
    report_reason=ProviderUnavailable
  fi
  jq -n --arg revision "$(jq -r '.owner.sourceSha' "$inputs")" \
    --arg runId "$(jq -r '.owner.runId' "$inputs")" --arg runAttempt "$(jq -r '.owner.runAttempt' "$inputs")" \
    --arg workflow "$(jq -r '.owner.workflowRef' "$inputs")" --arg action "$(jq -r '.selectors.actionId' "$inputs")" \
    --arg receipt "$receipt_id" --arg allocation "$allocation" --arg generation "$generation" \
    --arg cluster "$cluster_id" --arg garden "$(jq -r '.gardenLockDigest' "$inputs")" \
    --arg vendorDigest "$vendor_digest" --arg vendorOutcome "$vendor_outcome" \
    --arg vendorReason "$vendor_reason" --arg reportOutcome "$report_outcome" --arg reportReason "$report_reason" \
    --argjson required "$required" --slurpfile probes "$evidence/hostile-probes.json" \
    --slurpfile chain "$evidence/checkpoint-chain.json" '
    {apiVersion:"diene.atomi.cloud/ci-vendor-report/v1",repositoryRevision:$revision,
     workflow:{runId:$runId,runAttempt:$runAttempt,workflowRef:$workflow},lane:"ditto-vendor",
     profile:"ditto",buildMode:"build-local",actionId:$action,componentClass:"K9",
     permissionRule:"ditto-vendor-demo",receiptId:$receipt,
     instance:{allocationKey:$allocation,generationKey:$generation,substrateName:("diene-"+$allocation),
       clusterId:$cluster,osId:"wolfi",osVersion:"rolling",k3sVersion:"v1.33.1+k3s1",
       kubernetesVersion:"v1.33.1+k3s1",nodeCount:1,capacity:{cpu:"16",memory:"32Gi"}},
     tooling:{gardenLockDigest:$garden,journeyManifestDigest:$vendorDigest,nscVersion:"v0.0.532",
       sourceArchiveDigest:"sha256:4444444444444444444444444444444444444444444444444444444444444444",
       artifactSubjectDigest:"sha256:5555555555555555555555555555555555555555555555555555555555555555"},
     vendorOutcome:{id:$action,outcome:$vendorOutcome,reasonCode:$vendorReason,required:$required,durationSeconds:1},
     providerCleanup:{outcome:"Pass",reasonCode:"ProviderObjectsAbsent",objectIds:[],absenceProven:true,
       durableDebtRecord:null},credential:{issuer:"approved-environment-phase-broker",masked:true,
       issuedAfterReadiness:true,removed:true,removalObserved:true},
     evidence:{leakageScan:{outcome:"Pass",reasonCode:"ScanPendingFinalisation",encodings:[],scannedPaths:[]},
       egressCanary:{outcome:"Pass",reasonCode:"HostAndPodNegativeProbesPassed",mode:"allowlist",
         profileId:"ditto-vendor-v1",enforcement:"interim-in-guest-iptables-nft",
         platformStatus:"platform per-instance policy pending (support ask #4)",hostileProbes:$probes[0]},
       shipment:{outcome:"Unavailable",reasonCode:"CollectedByOuterOrchestrator"}},
     teardown:{outcome:"Pass",reasonCode:"ExactReceiptDestroyed",transitions:["ProviderCleanup:Pass","GardenAndPolicyCleanup:Pass"],
       finalizerWaitSeconds:0,debt:[],absenceProof:"ReceiptDestroyed"},checkpointChain:$chain[0],
     timings:{setupSeconds:1,substrateSeconds:1,readinessSeconds:1,journeysSeconds:1,teardownSeconds:1},
     outcome:$reportOutcome} + (if $reportReason == "" then {} else {reasonCode:$reportReason} end)' \
    >"$evidence/vendor-report.driver.json"
else
  jq -n --arg revision "$(jq -r '.owner.sourceSha' "$inputs")" \
    --arg runId "$(jq -r '.owner.runId' "$inputs")" --arg runAttempt "$(jq -r '.owner.runAttempt' "$inputs")" \
    --arg workflow "$(jq -r '.owner.workflowRef' "$inputs")" --arg lane "$lane" --arg profile "$profile" \
    --arg mode "$mode" --arg artifact "$(jq -r '.artifact.digest' "$inputs")" \
    --arg imageRef "$(jq -r '.artifact.imageRef' "$state/artifact-subject.json")" \
    --arg receipt "$receipt_id" --arg allocation "$allocation" --arg generation "$generation" \
    --arg cluster "$cluster_id" --arg garden "$(jq -r '.gardenLockDigest' "$inputs")" \
    --arg journey "$journey_digest" --arg profileId "$profile_id" --arg reportOutcome "$report_outcome" \
    --arg reportReason "$report_reason" --slurpfile readiness "$evidence/readiness.json" \
    --slurpfile probes "$evidence/hostile-probes.json" --slurpfile chain "$evidence/checkpoint-chain.json" '
    {apiVersion:"diene.atomi.cloud/ci-environment-report/v1",repositoryRevision:$revision,
     workflow:{runId:$runId,runAttempt:$runAttempt,workflowRef:$workflow},lane:$lane,profile:$profile,buildMode:$mode,
     subject:{artifactDigest:$artifact,imageRef:$imageRef,producerWorkflowRef:$workflow},
     instance:{allocationKey:$allocation,generationKey:$generation,substrateName:("diene-"+$allocation),
       clusterId:$cluster,osId:"wolfi",osVersion:"rolling",k3sVersion:"v1.33.1+k3s1",
       kubernetesVersion:"v1.33.1+k3s1",nodeCount:1,capacity:{cpu:"16",memory:"32Gi"}},receiptId:$receipt,
     tooling:{gardenLockDigest:$garden,journeyManifestDigest:$journey,nscVersion:"v0.0.532",
       sourceArchiveDigest:"sha256:4444444444444444444444444444444444444444444444444444444444444444",
       artifactSubjectDigest:"sha256:5555555555555555555555555555555555555555555555555555555555555555"},
     readiness:$readiness[0],journeys:[],coverage:[],
     evidence:{leakageScan:{outcome:"Pass",reasonCode:"ScanPendingFinalisation",encodings:[],scannedPaths:[]},
       egressCanary:{outcome:"Pass",reasonCode:"HostAndPodNegativeProbesPassed",mode:(if $lane == "absol" or $lane == "fleet-independence" then "closure-denied-network" else "allowlist" end),
         profileId:$profileId,enforcement:"interim-in-guest-iptables-nft",
         platformStatus:"platform per-instance policy pending (support ask #4)",hostileProbes:$probes[0]},
       shipment:{outcome:"Unavailable",reasonCode:"CollectedByOuterOrchestrator"}},
     teardown:{outcome:"Pass",reasonCode:"ExactReceiptDestroyed",transitions:["GardenExactDown:Pass","InterimPolicyRemoved:Pass"],
       finalizerWaitSeconds:0,debt:[],absenceProof:"ReceiptDestroyed"},checkpointChain:$chain[0],
     timings:{setupSeconds:1,substrateSeconds:1,readinessSeconds:1,journeysSeconds:1,teardownSeconds:1},
     outcome:$reportOutcome} + (if $reportReason == "" then {} else {reasonCode:$reportReason} end)' \
    >"$evidence/core-report.driver.json"
fi

if [[ $scenario == receipt-mismatch ]]; then
  jq '.owner.runId = "999999"' "$receipt" >"$evidence/ci-receipt.json"
else
  cp "$receipt" "$evidence/ci-receipt.json"
fi
jq -n --arg outcome "$([[ $driver_exit == 0 ]] && printf Pass || printf Fail)" \
  --arg reason "$([[ $driver_exit == 0 ]] && printf DriverCompleted || printf JourneyFailed)" \
  --argjson exitCode "$driver_exit" '{outcome:$outcome,reasonCode:$reason,exitCode:$exitCode}' \
  >"$evidence/driver-status.json"
tar -cf "$state/out/proof.tar" -C "$state" evidence
(cd "$state/out" && sha256sum proof.tar >proof.sha256)
GUEST
chmod 0755 "$fake_guest"

fake_nsc=$scratch/nsc
cat >"$fake_nsc" <<'NSC'
#!/usr/bin/env bash
set -euo pipefail
root=${FAKE_NSC_ROOT:?}
log=${FAKE_NSC_LOG:?}
scenario=${FAKE_NSC_SCENARIO:-happy}
install -d -m 0700 "$root/instances" "$root/stale"
printf '%q ' "$@" >>"$log"
printf '\n' >>"$log"
command=${1:-}
shift || true
case $command in
  version)
    (($# == 0)) || exit 127
    printf 'version v0.0.532\n'
    ;;
  create)
    ephemeral=false
    duration=
    wait_kube=false
    cidfile=
    metadata=
    output=
    purpose=
    unique_tag=
    labels=0
    while (($#)); do
      case $1 in
        --ephemeral) ephemeral=true; shift ;;
        --duration) duration=$2; shift 2 ;;
        --wait_kube_system) wait_kube=true; shift ;;
        --cidfile) cidfile=$2; shift 2 ;;
        --output_json_to) metadata=$2; shift 2 ;;
        --output) output=$2; shift 2 ;;
        --purpose) purpose=$2; shift 2 ;;
        --unique_tag) unique_tag=$2; shift 2 ;;
        --label) labels=$((labels + 1)); shift 2 ;;
        --machine_type) shift 2 ;;
        *) printf 'fake nsc: unsupported create argument %s\n' "$1" >&2; exit 127 ;;
      esac
    done
    [[ $ephemeral == true && $duration == 2h && $wait_kube == true && $output == json &&
      -n $cidfile && -n $metadata && -n $purpose && -n $unique_tag && $labels -eq 3 ]] || exit 65
    [[ $scenario != create-fail ]] || exit 41
    id="cluster-$(printf '%s' "$unique_tag" | sha256sum | cut -c1-16)"
    instance="$root/instances/$id"
    install -d -m 0700 "$instance/fs"
    jq -n --arg id "$id" --arg tag "$unique_tag" '{cluster_id:$id,unique_tag:$tag}' >"$instance/meta.json"
    : >"$instance/live"
    install -d -m 0700 "$(dirname -- "$cidfile")" "$(dirname -- "$metadata")"
    if [[ $scenario == cid-mismatch ]]; then printf '%s\n' "${id}-wrong" >"$cidfile"; else printf '%s\n' "$id" >"$cidfile"; fi
    jq -n --arg id "$id" '{cluster_id:$id}' >"$metadata"
    jq -n --arg id "$id" '{cluster_id:$id,instance_id:("instance-"+$id)}'
    ;;
  instance)
    sub=${1:-}; shift || true
    case $sub in
      upload)
        id=${1:?}; local_path=${2:?}; remote_path=${3:?}; flag=${4:-}; (($# == 4)) || exit 127
        [[ $flag == --mkdir && -f $root/instances/$id/live ]] || exit 66
        [[ $scenario != transfer-fail ]] || exit 47
        target="$root/instances/$id/fs/${remote_path#/}"
        install -d -m 0700 "$(dirname -- "$target")"
        cp "$local_path" "$target"
        ;;
      download)
        id=${1:?}; remote_path=${2:?}; local_path=${3:?}; flag=${4:-}; (($# == 4)) || exit 127
        [[ $flag == --mkdir && -f $root/instances/$id/live ]] || exit 66
        [[ $scenario != collection-fail ]] || exit 43
        source_path="$root/instances/$id/fs/${remote_path#/}"
        [[ -f $source_path ]] || exit 44
        install -d -m 0700 "$(dirname -- "$local_path")"
        cp "$source_path" "$local_path"
        ;;
      *) exit 127 ;;
    esac
    ;;
  ssh)
    id=${1:?}; flag=${2:-}; remote_command=${3:-}; (($# == 3)) || exit 127
    [[ $flag == -T && -n $remote_command && -f $root/instances/$id/live ]] || exit 66
    [[ $scenario != ssh-fail ]] || exit 42
    [[ $scenario != ssh-delay ]] || sleep 3
    "${FAKE_GUEST_BIN:?}" "$root/instances/$id/fs/run/diene-ci" "$id"
    ;;
  destroy)
    flag=${1:-}; id=${2:-}; (($# == 2)) || exit 127
    [[ $flag == --force && $id =~ ^cluster-[0-9a-f]{16}$ ]] || exit 66
    [[ $scenario != destroy-fail ]] || exit 45
    rm -f -- "$root/instances/$id/live"
    if [[ $scenario == absence-fail ]]; then cp "$root/instances/$id/meta.json" "$root/stale/$id.json"; fi
    ;;
  list)
    [[ ${1:-} == --all && ${2:-} == -o && ${3:-} == json && $# -eq 3 ]] || exit 127
    [[ $scenario != list-fail ]] || exit 46
    listing=$(find "$root/instances" -mindepth 2 -maxdepth 2 -name live -print0 |
      while IFS= read -r -d '' live; do jq -c . "$(dirname -- "$live")/meta.json"; done | jq -s .)
    if [[ $scenario == absence-fail ]]; then
      listing=$(find "$root/stale" -maxdepth 1 -type f -name '*.json' -print0 |
        while IFS= read -r -d '' stale; do jq -c . "$stale"; done | jq -s .)
    fi
    if [[ $listing == '[]' ]]; then printf 'null\n'; else printf '%s\n' "$listing"; fi
    ;;
  *) printf 'fake nsc: unsupported command %s\n' "$command" >&2; exit 127 ;;
esac
NSC
chmod 0755 "$fake_nsc"

prepare_run() {
  local run_id=${1:?run id required}
  local lane=${2:-ditto-build-local}
  local runner=${3:-$scratch/runner-$run_id}
  local nsc_root=${4:-$scratch/nsc-$run_id}
  install -d -m 0700 "$runner" "$nsc_root"
  write_subject "$runner/artifact-subject.json" "$run_id" 1
  export GITHUB_REPOSITORY_ID=12345 GITHUB_REPOSITORY=AtomiCloud/example GITHUB_SHA=$SOURCE_SHA
  export GITHUB_RUN_ID=$run_id GITHUB_RUN_ATTEMPT=1 DIENE_BASE_WORKFLOW_REF=$WORKFLOW_REF
  export DIENE_LANE=$lane DIENE_GARDEN_LOCK_DIGEST=$GARDEN_DIGEST DIENE_ARTIFACT_DIGEST=$ARTIFACT_DIGEST
  export DIENE_ARTIFACT_SUBJECT="$runner/artifact-subject.json" DIENE_TRUSTED_RUNTIME_CONTEXT=protected-base
  export DIENE_JOURNEY_MANIFEST=.diene/ci/journeys.v1.yaml DIENE_VENDOR_MANIFEST='' DIENE_ACTION_ID=''
  export DIENE_FIXTURE_ID='' DIENE_NSC_DURATION=2h DIENE_SOURCE_ARCHIVE=$source_archive
  export DIENE_CONNECTED_EGRESS_JSON='[{"dns":"api.example.test","sni":"api.example.test","port":443,"methods":["GET","POST"]}]'
  export DIENE_EGRESS_CANARY_IMAGE=$CANARY_IMAGE DIENE_EGRESS_L7_ENFORCER_BIN=.diene/ci/l7-enforcer
  export DIENE_EGRESS_PROBE_BIN=.diene/ci/egress-probe DIENE_VENDOR_CREDENTIAL_BROKER_BIN=''
  export DIENE_ADMITTED_K3S_VERSION=v1.33.1+k3s1 DIENE_K3S_SERVICE_CIDR=10.143.0.0/16
  export DIENE_ORCHESTRATOR_VENUE=local DIENE_ORCHESTRATOR_LABEL=local-contract-test
  export DIENE_ORCHESTRATOR_FALLBACK_REASON='' DIENE_NSC_BIN=$fake_nsc
  export FAKE_NSC_ROOT=$nsc_root FAKE_NSC_LOG=$nsc_root/log FAKE_GUEST_BIN=$fake_guest
  export TEMPLATE_SCRIPT_DIR=$work/scripts/ci RUNNER_TEMP=$runner DIENE_SCHEMA_DIR=$work/schemas/ci
  export DIENE_CORE_REPORT=$runner/diene-environment-report.v1.json
  export DIENE_VENDOR_REPORT=$runner/diene-vendor-report.v1.json
  export DIENE_PROOF_BUNDLE=$runner/diene-proof-bundle.tar
  export DIENE_LEAK_CANARY="contract-canary-$run_id" DIENE_NSC_ABSENCE_WAIT_SECONDS=0
  export DIENE_NSC_ABSENCE_INTERVAL_SECONDS=1 GITHUB_OUTPUT=$runner/github-output
  export GITHUB_ENV=$runner/github-env GITHUB_STEP_SUMMARY=$runner/summary
  : >"$FAKE_NSC_LOG"; : >"$GITHUB_OUTPUT"; : >"$GITHUB_ENV"; : >"$GITHUB_STEP_SUMMARY"
  unset DIENE_ARTIFACT_PROVENANCE_REF DIENE_ARTIFACT_ATTESTATION_DIGEST
  unset DIENE_CLOSURE_DIGEST DIENE_CLOSURE_BUNDLE_REF
  unset DIENE_CLOSURE_SIGNATURE_BUNDLE_DIGEST DIENE_CLOSURE_TRUST_ROOT_DIGEST
  unset DIENE_NAMESPACE_INGRESS DIENE_PUBLIC_ENDPOINT DIENE_NSC_CACHE_TAG DIENE_CACHE_DIR
  unset DIENE_SEED_IDENTITY DIENE_VENDOR_CREDENTIAL DIENE_NSC_MACHINE_TYPE GITHUB_WORKSPACE
  unset DIENE_PRE_SIT_NEGATIVE_CANARY DIENE_PRE_SIT_FIXTURE_ROOT
  unset FAKE_L7_COMPLETE FAKE_PROBE_FAIL_SCOPE FAKE_L7_LOG FAKE_PROBE_LOG FAKE_BROKER_LOG
  unset FAKE_TABLE_FAIL_REGEX FAKE_RESOLVER_IPV4 FAKE_BROKER_FAIL_COMMAND
  if [[ $lane == ditto-target-pull ]]; then
    export DIENE_ARTIFACT_PROVENANCE_REF="oci://ghcr.io/atomicloud/example/provenance/$SOURCE_SHA"
    export DIENE_ARTIFACT_ATTESTATION_DIGEST=$ATTESTATION_DIGEST
    export DIENE_CONNECTED_EGRESS_JSON='[{"dns":"ghcr.io","sni":"ghcr.io","port":443,"methods":["GET"]}]'
  elif [[ $lane == absol ]]; then
    export DIENE_CLOSURE_DIGEST=$CLOSURE_DIGEST
    export DIENE_CLOSURE_BUNDLE_REF="oci://ghcr.io/atomicloud/example/closure/$SOURCE_SHA"
    export DIENE_CLOSURE_SIGNATURE_BUNDLE_DIGEST=$CLOSURE_SIGNATURE_DIGEST
    export DIENE_CLOSURE_TRUST_ROOT_DIGEST=$CLOSURE_ROOT_DIGEST
  elif [[ $lane == fleet-independence ]]; then
    export DIENE_FIXTURE_ID=bootstrap-fleet-independence-v1
  elif [[ $lane == ditto-vendor ]]; then
    export DIENE_JOURNEY_MANIFEST='' DIENE_VENDOR_MANIFEST=.diene/ci/vendors.v1.yaml
    export DIENE_ACTION_ID=demo-vendor DIENE_VENDOR_CREDENTIAL_BROKER_BIN=.diene/ci/vendor-broker
    export DIENE_CONNECTED_EGRESS_JSON=''
  fi
}

run_orchestrator() {
  local scenario=${1:-happy}
  (cd -- "$work" && FAKE_NSC_SCENARIO=$scenario ./scripts/ci/environment-k3d-run.sh orchestrate)
}

printf '== harness bootstrap ==\n'
ok 'local fixture and measured fake-nsc surface are ready'

# Test sections are intentionally below the leakage canary section too: a
# canary refusal must not terminate the parent harness before the final tail.

assert_contains() {
  local file=${1:?file required} needle=${2:?needle required}
  grep -Fq -- "$needle" "$file" || fail "$file does not contain $needle"
}

assert_not_contains() {
  local file=${1:?file required} needle=${2:?needle required}
  ! grep -Fq -- "$needle" "$file" || fail "$file unexpectedly contains $needle"
}

printf '== static workflow and compatibility ABI ==\n'

workflow=$template_root/.github/workflows/⚡reusable-environment-k3d.yaml
for job in environment-ditto-build-local environment-ditto-target-pull environment-ditto-vendor \
  environment-absol environment-fleet-independence environment-runner-lifecycle; do
  grep -Eq "^  ${job}:" "$workflow" || fail "stable workflow job $job is absent"
done
ok 'all six runtime/lifecycle job IDs remain stable'

for entrypoint in environment-profile-contract.sh environment-k3d-run.sh environment-vendor-run.sh \
  environment-report.sh environment-receipt-sweep.sh environment-runner-preflight.sh; do
  [[ -x $script_dir/$entrypoint ]] || fail "retained entrypoint $entrypoint is absent or non-executable"
done
[[ ! -e $script_dir/environment-nsc-lifecycle.sh ]] ||
  fail 'an unratified seventh environment-nsc-lifecycle entrypoint was added'
ok 'the exact six retained entrypoints own the lifecycle surface'

[[ ! -e $template_root/schemas/ci/diene-runner-pin-v1.schema.json &&
  ! -e $template_root/schemas/ci/diene-host-policy-v1.schema.json ]] ||
  fail 'a shelved DigitalOcean runner schema remains active'
jq -e '.properties.substrate.properties.kind.const == "k3d"' \
  "$template_root/schemas/ci/diene-runtime-consumption-v1.schema.json" >/dev/null ||
  fail 'the Garden-owned opaque runtime-consumption ABI changed'
ok 'DO-only schemas are retired while the Garden k3d compatibility field remains opaque'

grep -Fq 'runs-on: nscloud-ubuntu-26.04-amd64-16x32' "$workflow" ||
  fail 'runtime jobs do not use the ratified Namespace 26.04 label'
grep -Fq 'runs-on: ubuntu-24.04' "$workflow" ||
  fail 'the documented GitHub-hosted 24.04 fallback is absent'
grep -Fq 'platform per-instance policy pending (support ask #4)' \
  "$template_root/scripts/ci/environment-k3d-run.sh" ||
  fail 'the interim platform-policy status is not stamped into workflow evidence'
ok 'runner labels and the interim support-ask stamp are explicit'

if rg -n 'runs-on:.*self-hosted|digitalocean|doctl|k3d (cluster|create|delete)|k3s ctr images export|nsc ingress|actions/cache' \
  --glob '!test-environment-contract.sh' "$template_root/.github/workflows" \
  "$template_root/scripts/ci" >"$scratch/forbidden-static"; then
  sed -n '1,120p' "$scratch/forbidden-static" >&2
  fail 'an executable workflow/script revives a forbidden substrate or cache path'
fi
if rg -n 'runner-pin|host-policy|leaseId|DigitalOcean|JIT' --glob '!test-environment-contract.sh' \
  "$workflow" "$template_root/scripts/ci" \
  >"$scratch/forbidden-shelved"; then
  sed -n '1,120p' "$scratch/forbidden-shelved" >&2
  fail 'the active runtime surface still depends on shelved runner apparatus'
fi
ok 'active code contains no self-hosted, DO, nested-k3d, ingress, cache, or export path'

for input in lane repository_id repository_key source_sha garden_lock_digest artifact_digest \
  artifact_provenance_ref artifact_attestation_digest journey_manifest vendor_manifest action_id \
  closure_digest closure_bundle_ref closure_signature_bundle_digest closure_trust_root_digest; do
  grep -Eq "^      ${input}:" "$workflow" || fail "workflow_call input $input is absent"
done
for output in subject_digest receipt_id core_report_digest vendor_report_digest; do
  grep -Eq "^      ${output}:" "$workflow" || fail "workflow_call output $output is absent"
done
ok 'workflow_call retains the complete ratified v1 input/output vocabulary'

printf '== every cheap refusal precedes nsc create ==\n'

prepare_run 3001
export DIENE_TRUSTED_RUNTIME_CONTEXT=untrusted-pull-request
expect_precreate_refusal UntrustedSubject ./scripts/ci/environment-k3d-run.sh orchestrate

prepare_run 3002
export DIENE_NSC_DURATION=45m
expect_precreate_refusal InputContractInvalid ./scripts/ci/environment-k3d-run.sh orchestrate

prepare_run 3003
export DIENE_NAMESPACE_INGRESS=generated.namespace.example
expect_precreate_refusal InputContractInvalid ./scripts/ci/environment-k3d-run.sh orchestrate

prepare_run 3004 absol
export DIENE_NSC_CACHE_TAG=shared-cache
expect_precreate_refusal InputContractInvalid ./scripts/ci/environment-k3d-run.sh orchestrate

prepare_run 3005 fleet-independence
export DIENE_SEED_IDENTITY=forbidden-seed
expect_precreate_refusal InputContractInvalid ./scripts/ci/environment-k3d-run.sh orchestrate

prepare_run 3006
export DIENE_LANE=unknown-lane
expect_precreate_refusal InputContractInvalid ./scripts/ci/environment-k3d-run.sh orchestrate

prepare_run 3007
export DIENE_JOURNEY_MANIFEST=.diene/ci/other-journeys.yaml
expect_precreate_refusal InputContractInvalid ./scripts/ci/environment-k3d-run.sh orchestrate

prepare_run 3008 ditto-vendor
export DIENE_JOURNEY_MANIFEST=.diene/ci/journeys.v1.yaml
expect_precreate_refusal InputContractInvalid ./scripts/ci/environment-k3d-run.sh orchestrate

prepare_run 3009 ditto-target-pull
unset DIENE_ARTIFACT_PROVENANCE_REF
expect_precreate_refusal InputContractInvalid ./scripts/ci/environment-k3d-run.sh orchestrate

prepare_run 3010 ditto-target-pull
export DIENE_ARTIFACT_ATTESTATION_DIGEST=$CLOSURE_DIGEST
expect_precreate_refusal UntrustedSubject ./scripts/ci/environment-k3d-run.sh orchestrate

prepare_run 3011 ditto-target-pull
export DIENE_CONNECTED_EGRESS_JSON='[{"dns":"api.example.test","sni":"api.example.test","port":443,"methods":["GET"]}]'
expect_precreate_refusal ConnectedEgressInterfaceUnavailable ./scripts/ci/environment-k3d-run.sh orchestrate

prepare_run 3012 absol
export DIENE_CLOSURE_DIGEST=$ATTESTATION_DIGEST
expect_precreate_refusal UntrustedSubject ./scripts/ci/environment-k3d-run.sh orchestrate

prepare_run 3013 absol
unset DIENE_CLOSURE_SIGNATURE_BUNDLE_DIGEST
expect_precreate_refusal InputContractInvalid ./scripts/ci/environment-k3d-run.sh orchestrate

prepare_run 3014
write_subject "$DIENE_ARTIFACT_SUBJECT" 999999 1
expect_precreate_refusal UntrustedSubject ./scripts/ci/environment-k3d-run.sh orchestrate

prepare_run 3015
chmod 0644 "$work/.diene/ci/artifact-producer.sh"
expect_precreate_refusal ArtifactProducerUnavailable ./scripts/ci/environment-k3d-run.sh orchestrate
chmod 0755 "$work/.diene/ci/artifact-producer.sh"

prepare_run 3016
export DIENE_PRE_SIT_NEGATIVE_CANARY=1
expect_precreate_refusal ProductionFixtureInvalid ./scripts/ci/environment-k3d-run.sh orchestrate
unset DIENE_PRE_SIT_NEGATIVE_CANARY

fixture_backup=$scratch/demo-manifest.backup
cp "$work/.diene/ci/fixtures/demo/manifest.yaml" "$fixture_backup"
prepare_run 3017
printf '%s\n' '{"apiVersion":"diene.atomi.cloud/ci-fixture/v1","id":"demo","duration":"sixty-minutes"}' \
  >"$work/.diene/ci/fixtures/demo/manifest.yaml"
expect_precreate_refusal ProductionFixtureInvalid ./scripts/ci/environment-k3d-run.sh orchestrate
cp "$fixture_backup" "$work/.diene/ci/fixtures/demo/manifest.yaml"

prepare_run 3018
printf '%s\n' '{"apiVersion":"diene.atomi.cloud/ci-fixture/v1","id":"demo","duration":"60m"}' \
  >"$work/.diene/ci/fixtures/demo/manifest.yaml"
expect_precreate_refusal ProductionFixtureInvalid ./scripts/ci/environment-k3d-run.sh orchestrate
cp "$fixture_backup" "$work/.diene/ci/fixtures/demo/manifest.yaml"

prepare_run 3019 ditto-vendor
export DIENE_VENDOR_CREDENTIAL_BROKER_BIN=''
expect_precreate_refusal VendorBrokerInterfaceUnavailable ./scripts/ci/environment-k3d-run.sh orchestrate

prepare_run 3020
export DIENE_EGRESS_L7_ENFORCER_BIN=/tmp/untrusted-l7-enforcer
expect_precreate_refusal ConnectedEgressInterfaceUnavailable ./scripts/ci/environment-k3d-run.sh orchestrate

vendor_backup=$scratch/vendors.backup
cp "$work/.diene/ci/vendors.v1.yaml" "$vendor_backup"
prepare_run 3021 ditto-vendor
jq '.actions[0].componentClass = "K10" | .actions[0].permissionRule = "off"' \
  "$vendor_backup" >"$work/.diene/ci/vendors.v1.yaml"
expect_precreate_refusal SchemaValidationFailed ./scripts/ci/environment-k3d-run.sh orchestrate
cp "$vendor_backup" "$work/.diene/ci/vendors.v1.yaml"
ok 'trust, selectors, closure, vendor, producer, and fixture defects all stop before create'

printf '== exact measured Namespace happy path ==\n'

run_happy_lane() {
  local run_id=${1:?run id required} lane=${2:?lane required} scenario=${3:-happy}
  prepare_run "$run_id" "$lane"
  run_orchestrator "$scenario" >"$scratch/happy-$run_id.out" 2>"$scratch/happy-$run_id.err" || {
    sed -n '1,160p' "$scratch/happy-$run_id.err" >&2
    fail "$lane happy lifecycle failed"
  }
  LAST_REPORT=$DIENE_CORE_REPORT
  [[ $lane != ditto-vendor ]] || LAST_REPORT=$DIENE_VENDOR_REPORT
  [[ -s $LAST_REPORT && -s $DIENE_PROOF_BUNDLE ]] || fail "$lane produced no final report/proof"
  jq -e '
    .namespaceLifecycle.duration == "2h" and .namespaceLifecycle.ephemeral == true and
    .namespaceLifecycle.endpointUsed == false and .namespaceLifecycle.cacheAttached == false and
    .namespaceLifecycle.lateCleanupCanRewrite == false and
    ([.namespaceLifecycle.create,.namespaceLifecycle.transfer,.namespaceLifecycle.ssh,
      .namespaceLifecycle.collection,.namespaceLifecycle.destroy,.namespaceLifecycle.absence] |
      all(.outcome == "Pass")) and .checkpointChain.validated == true and
    .checkpointChain.finalCleanPass == true and .checkpointChain.resumedLegs == 0 and
    .evidence.egressCanary.platformStatus ==
      "platform per-instance policy pending (support ask #4)"
  ' "$LAST_REPORT" >/dev/null || fail "$lane final lifecycle evidence is not complete"
  LAST_CLUSTER=$(jq -er '.instance.clusterId' "$LAST_REPORT")
  LAST_LOG=$FAKE_NSC_LOG
  LAST_BUNDLE=$DIENE_PROOF_BUNDLE
}

run_happy_lane 4001 ditto-build-local
happy_core_report=$scratch/happy-core.json
happy_core_bundle=$scratch/happy-core-proof.tar
cp "$LAST_REPORT" "$happy_core_report"
cp "$LAST_BUNDLE" "$happy_core_bundle"
happy_cluster=$LAST_CLUSTER
happy_log=$LAST_LOG

grep -Eq '^create --ephemeral --duration 2h --wait_kube_system .*--output_json_to .*--output json .*--purpose .*--unique_tag .*--label .*--label .*--label ' \
  "$happy_log" || fail 'fake nsc did not observe the exact stable create surface'
[[ $(grep -Ec '^instance upload ' "$happy_log") == 5 ]] || fail 'immutable upload count is not exactly five'
[[ $(grep -Ec '^instance download ' "$happy_log") == 2 ]] || fail 'fixed proof download count is not exactly two'
grep -Eq "^ssh ${happy_cluster} -T " "$happy_log" || fail 'driver did not use exact-id noninteractive ssh'
[[ $(grep -Ec "^destroy --force ${happy_cluster} " "$happy_log") == 1 ]] ||
  fail 'cleanup did not issue exactly one exact-id force destroy'
grep -Eq '^list --all -o json ' "$happy_log" || fail 'positive absence did not query the complete list'
if grep -Eq '^destroy .*diene_|^destroy .*\*|^destroy .*--label|^(scp|cp|ingress|egress) ' "$happy_log"; then
  fail 'the Namespace adapter used a prefix, broad selector, invented copy verb, ingress, or tenant policy'
fi
[[ $(FAKE_NSC_SCENARIO=happy "$fake_nsc" list --all -o json) == null ]] ||
  fail 'the measured empty-list null result was not normalized as exact absence'
ok 'create/cid agreement/upload/ssh/download/exact destroy/list absence use measured nsc syntax'

nsc_lines_before=$(wc -l <"$happy_log")
(cd -- "$work" && FAKE_NSC_SCENARIO=happy ./scripts/ci/environment-k3d-run.sh lifecycle "$happy_core_bundle") \
  >"$scratch/lifecycle.out" 2>"$scratch/lifecycle.err" || {
  sed -n '1,120p' "$scratch/lifecycle.err" >&2
  fail 'workflow-owned lifecycle verifier rejected the green proof'
}
[[ $(wc -l <"$happy_log") == "$nsc_lines_before" ]] ||
  fail 'the unprivileged lifecycle verifier invoked Namespace authority'
assert_contains "$scratch/lifecycle.out" 'NamespaceLifecycleVerified:'
ok 'workflow-owned lifecycle verification consumes proof without nsc authority'

destroy_before=$(grep -Ec '^destroy ' "$happy_log")
(cd -- "$work" && FAKE_NSC_SCENARIO=happy ./scripts/ci/environment-k3d-run.sh cleanup) \
  >"$scratch/cleanup.out" 2>"$scratch/cleanup.err" || {
  sed -n '1,120p' "$scratch/cleanup.err" >&2
  fail 'normal always-step cleanup did not re-prove convergence'
}
[[ $(grep -Ec '^destroy ' "$happy_log") == "$destroy_before" ]] ||
  fail 'normal always-step cleanup destroyed an already-converged instance twice'
assert_contains "$scratch/cleanup.out" 'NamespaceLifecycleConverged:'
ok 'the separate always-step re-proves absence without a duplicate destroy'

run_happy_lane 4002 ditto-target-pull
cp "$LAST_REPORT" "$scratch/happy-target-pull.json"
run_happy_lane 4003 absol
assert_not_contains "$LAST_LOG" '--cache'
run_happy_lane 4004 fleet-independence
assert_not_contains "$LAST_LOG" '--cache'
run_happy_lane 4005 ditto-vendor
happy_vendor_report=$scratch/happy-vendor.json
cp "$LAST_REPORT" "$happy_vendor_report"
grep -Fq 'vendor_report_digest=sha256:' "$GITHUB_OUTPUT" || fail 'vendor output digest is absent'
! grep -Fq 'core_report_digest=' "$GITHUB_OUTPUT" || fail 'vendor run opened the core output namespace'
run_happy_lane 4006 ditto-vendor vendor-unavailable
jq -e '.outcome == "Unavailable" and .vendorOutcome.outcome == "Unavailable" and
  .vendorOutcome.required == false and .namespaceLifecycle.outcome == "Pass"' "$LAST_REPORT" >/dev/null ||
  fail 'optional provider unavailability was not nonblocking and separately explicit'
ok 'all five lanes converge; optional vendor unavailability alone remains nonblocking'

printf '== lifecycle phase failures stay red and exact ==\n'

expect_lifecycle_failure() {
  local run_id=${1:?run id required} scenario=${2:?scenario required} reason=${3:?reason required}
  prepare_run "$run_id"
  local nsc_root=$FAKE_NSC_ROOT rc
  if run_orchestrator "$scenario" >"$scratch/failure-$scenario.out" 2>"$scratch/failure-$scenario.err"; then
    fail "$scenario unexpectedly passed"
  else
    rc=$?
  fi
  ((rc != 0)) || fail "$scenario returned a green status"
  grep -Fq -- "$reason" "$scratch/failure-$scenario.err" || {
    sed -n '1,160p' "$scratch/failure-$scenario.err" >&2
    fail "$scenario did not retain $reason"
  }
  if grep -Eq '^destroy .*diene_|^destroy .*\*|^destroy .*--label' "$FAKE_NSC_LOG"; then
    fail "$scenario attempted prefix or broad cleanup"
  fi
  FAILURE_NSC_ROOT=$nsc_root
  FAILURE_LOG=$FAKE_NSC_LOG
  ok "$scenario remains red with $reason"
}

expect_lifecycle_failure 5001 create-fail NamespaceCreateFailed
! find "$FAILURE_NSC_ROOT/instances" -name live -print -quit | grep -q . ||
  fail 'a failed create unexpectedly left a modeled live instance'
! grep -Eq '^destroy ' "$FAILURE_LOG" || fail 'failed create guessed an identity to destroy'

expect_lifecycle_failure 5002 transfer-fail NamespaceTransferFailed
transfer_id=$(find "$FAILURE_NSC_ROOT/instances" -name meta.json -exec jq -r '.cluster_id' {} \;)
[[ $(grep -Ec "^destroy --force ${transfer_id} " "$FAILURE_LOG") == 1 ]] ||
  fail 'transfer failure did not destroy its exact cluster once'
[[ ! -e $FAILURE_NSC_ROOT/instances/$transfer_id/live ]] || fail 'transfer failure left its cluster live'

expect_lifecycle_failure 5003 ssh-fail NamespaceSshDriverFailed
ssh_id=$(find "$FAILURE_NSC_ROOT/instances" -name meta.json -exec jq -r '.cluster_id' {} \;)
[[ $(grep -Ec "^destroy --force ${ssh_id} " "$FAILURE_LOG") == 1 ]] ||
  fail 'SSH failure did not destroy its exact cluster once'
[[ ! -e $FAILURE_NSC_ROOT/instances/$ssh_id/live ]] || fail 'SSH failure left its cluster live'

expect_lifecycle_failure 5004 collection-fail EvidenceCollectionFailed
collection_id=$(find "$FAILURE_NSC_ROOT/instances" -name meta.json -exec jq -r '.cluster_id' {} \;)
[[ $(grep -Ec "^destroy --force ${collection_id} " "$FAILURE_LOG") == 1 ]] ||
  fail 'download failure did not destroy its exact cluster once'
[[ ! -e $FAILURE_NSC_ROOT/instances/$collection_id/live ]] || fail 'download failure left its cluster live'

expect_lifecycle_failure 5005 destroy-fail NamespaceDestroyFailed
destroy_id=$(find "$FAILURE_NSC_ROOT/instances" -name meta.json -exec jq -r '.cluster_id' {} \;)
[[ $(grep -Ec "^destroy --force ${destroy_id} " "$FAILURE_LOG") == 1 ]] ||
  fail 'destroy failure did not retain its exact destructive selector'
[[ -e $FAILURE_NSC_ROOT/instances/$destroy_id/live ]] ||
  fail 'the destroy-failure model incorrectly claimed the instance absent'
assert_contains "$scratch/failure-destroy-fail.err" 'NamespaceAbsenceUnproven'

expect_lifecycle_failure 5006 list-fail NamespaceAbsenceUnproven
list_id=$(find "$FAILURE_NSC_ROOT/instances" -name meta.json -exec jq -r '.cluster_id' {} \;)
[[ $(grep -Ec "^destroy --force ${list_id} " "$FAILURE_LOG") == 1 ]] ||
  fail 'list failure did not destroy its exact cluster once'
[[ ! -e $FAILURE_NSC_ROOT/instances/$list_id/live ]] || fail 'list failure left its cluster live'
grep -Eq '^list --all -o json ' "$FAILURE_LOG" || fail 'list failure never attempted positive absence'
ok 'all modeled lifecycle phase failures preserve exact-id cleanup semantics'

printf '== identity mismatch, driver failure, and cancellation ==\n'

expect_lifecycle_failure 5101 cid-mismatch NamespaceIdentityMismatch
cid_mismatch_id=$(find "$FAILURE_NSC_ROOT/instances" -name meta.json -exec jq -r '.cluster_id' {} \;)
[[ -e $FAILURE_NSC_ROOT/instances/$cid_mismatch_id/live ]] ||
  fail 'cid mismatch did not remain visible as TTL-backed cleanup debt'
! grep -Eq '^destroy ' "$FAILURE_LOG" ||
  fail 'cid mismatch guessed between disagreeing identities and destroyed one'
ok 'cidfile/metadata disagreement refuses without broad or guessed cleanup'

expect_lifecycle_failure 5102 driver-fail DriverFailed
driver_id=$(find "$FAILURE_NSC_ROOT/instances" -name meta.json -exec jq -r '.cluster_id' {} \;)
[[ $(grep -Ec "^destroy --force ${driver_id} " "$FAILURE_LOG") == 1 ]] ||
  fail 'driver failure did not destroy its exact cluster once'
[[ ! -e $FAILURE_NSC_ROOT/instances/$driver_id/live ]] || fail 'driver failure left its cluster live'
jq -e '.outcome == "Fail" and .namespaceLifecycle.destroy.outcome == "Pass" and
  .namespaceLifecycle.absence.outcome == "Pass"' "$DIENE_CORE_REPORT" >/dev/null ||
  fail 'driver failure was rewritten green by successful cleanup'
ok 'driver failure remains red after exact destroy and absence both pass'

cancel_lifecycle() {
  local run_id=${1:?run id required} signal=${2:?signal required} expected=${3:?status required}
  prepare_run "$run_id"
  local pidfile=$scratch/cancel-$signal.pid killer rc cluster
  (
    local attempt pid=''
    for ((attempt = 0; attempt < 200; attempt++)); do
      [[ ! -s $pidfile ]] || read -r pid <"$pidfile"
      if [[ -n $pid ]] && grep -Eq '^ssh ' "$FAKE_NSC_LOG"; then
        kill -s "$signal" "$pid"
        exit 0
      fi
      sleep 0.05
    done
    exit 1
  ) &
  killer=$!
  if (
    cd -- "$work"
    printf '%s\n' "$BASHPID" >"$pidfile"
    exec env FAKE_NSC_SCENARIO=ssh-delay ./scripts/ci/environment-k3d-run.sh orchestrate
  ) >"$scratch/cancel-$signal.out" 2>"$scratch/cancel-$signal.err"; then
    wait "$killer" || true
    fail "$signal cancellation unexpectedly passed"
  else
    rc=$?
  fi
  wait "$killer" || fail "$signal cancellation was not injected during SSH"
  [[ $rc == "$expected" ]] || fail "$signal cancellation returned $rc, expected $expected"
  assert_contains "$scratch/cancel-$signal.err" OrchestratorCancelled
  cluster=$(find "$FAKE_NSC_ROOT/instances" -name meta.json -exec jq -r '.cluster_id' {} \;)
  [[ $(grep -Ec "^destroy --force ${cluster} " "$FAKE_NSC_LOG") == 1 ]] ||
    fail "$signal cancellation did not destroy its exact cluster once"
  [[ ! -e $FAKE_NSC_ROOT/instances/$cluster/live ]] || fail "$signal cancellation left its cluster live"
  jq -e '.outcome == "Fail" and .reasonCode == "OrchestratorCancelled" and
    .namespaceLifecycle.destroy.outcome == "Pass" and .namespaceLifecycle.absence.outcome == "Pass"' \
    "$DIENE_CORE_REPORT" >/dev/null || fail "$signal cancellation report lost its original red result"
  ok "$signal cancellation remains red after exact cleanup"
}

cancel_lifecycle 5110 TERM 143
cancel_lifecycle 5111 INT 130

printf '== late cleanup closes debt but cannot rewrite red ==\n'

expect_lifecycle_failure 5120 absence-fail NamespaceAbsenceUnproven
late_id=$(find "$FAILURE_NSC_ROOT/instances" -name meta.json -exec jq -r '.cluster_id' {} \;)
late_report_digest=$(sha256sum "$DIENE_CORE_REPORT" | awk '{print $1}')
if (cd -- "$work" && FAKE_NSC_SCENARIO=happy ./scripts/ci/environment-k3d-run.sh cleanup) \
  >"$scratch/late-cleanup.out" 2>"$scratch/late-cleanup.err"; then
  fail 'late cleanup rewrote a failed lifecycle green'
fi
assert_contains "$scratch/late-cleanup.err" LateCleanupCannotRewriteRun
[[ $(grep -Ec "^destroy --force ${late_id} " "$FAILURE_LOG") == 2 ]] ||
  fail 'late cleanup did not remain scoped to the same exact cluster_id'
late_record=$(find "$RUNNER_TEMP/diene-namespace" -path '*/final-proof/late-cleanup.json' -print -quit)
jq -e --arg cluster "$late_id" '.outcome == "Fail" and
  .reasonCode == "LateExactCleanupCannotRewriteRun" and .clusterId == $cluster and
  .absenceProven == true and .lateCleanupCanRewrite == false' "$late_record" >/dev/null ||
  fail 'late cleanup did not emit durable exact-id red evidence'
[[ $(sha256sum "$DIENE_CORE_REPORT" | awk '{print $1}') == "$late_report_digest" ]] ||
  fail 'late cleanup mutated the original failed report'
ok 'late exact cleanup can close debt but never rewrite the failed run green'

printf '== receipt sweep refuses malformed, cross-run, empty, and prefix selectors ==\n'

fake_pls=$scratch/fake-pls
cat >"$fake_pls" <<'PLS'
#!/usr/bin/env bash
set -euo pipefail
printf '%q ' "$@" >>"${FAKE_PLS_LOG:?}"
printf '\n' >>"${FAKE_PLS_LOG:?}"
exit 0
PLS
chmod 0755 "$fake_pls"
fake_pls_log=$scratch/fake-pls.log
: >"$fake_pls_log"

valid_receipt=$(find "$RUNNER_TEMP/diene-receipts" -maxdepth 1 -type f -name '*.json' -print -quit)
receipt_id=$(jq -er '.owner.receiptId' "$valid_receipt")

expect_sweep_refusal() {
  local reason=${1:?reason required} receipt_dir=${2:?receipt dir required}
  local repository_id=${3:?repository id required} run_id=${4:?run id required}
  local run_attempt=${5:?run attempt required} selected_receipt=${6-}
  if (cd -- "$work" && DIENE_RECEIPT_DIR="$receipt_dir" DIENE_PLS_BIN="$fake_pls" \
    FAKE_PLS_LOG="$fake_pls_log" ./scripts/ci/environment-receipt-sweep.sh \
      --repository-id "$repository_id" --run-id "$run_id" --run-attempt "$run_attempt" \
      --receipt-id "$selected_receipt") >"$scratch/sweep.out" 2>"$scratch/sweep.err"; then
    fail "receipt sweep unexpectedly accepted $reason case"
  fi
  grep -Fq -- "$reason" "$scratch/sweep.err" || {
    sed -n '1,120p' "$scratch/sweep.err" >&2
    fail "receipt sweep did not report $reason"
  }
  ok "receipt sweep refuses $reason"
}

malformed_dir=$scratch/receipts-malformed
install -d -m 0700 "$malformed_dir"
jq 'del(.namespace.duration)' "$valid_receipt" >"$malformed_dir/receipt.json"
expect_sweep_refusal SchemaValidationFailed "$malformed_dir" 12345 5120 1 "$receipt_id"

cross_run_dir=$scratch/receipts-cross-run
install -d -m 0700 "$cross_run_dir"
cp "$valid_receipt" "$cross_run_dir/receipt.json"
expect_sweep_refusal CleanupDebt "$cross_run_dir" 12345 999999 1 "$receipt_id"

empty_dir=$scratch/receipts-empty
install -d -m 0700 "$empty_dir"
expect_sweep_refusal CleanupDebt "$empty_dir" 12345 5120 1 "$receipt_id"

receipt_prefix=${receipt_id%-*}
expect_sweep_refusal CleanupDebt "$cross_run_dir" 12345 5120 1 "$receipt_prefix"
expect_sweep_refusal InputContractInvalid "$cross_run_dir" 12345 5120 1 ''
[[ ! -s $fake_pls_log ]] || fail 'a refused receipt selector invoked Garden teardown'
ok 'every refused receipt selector performs zero deletion'

printf '== two parallel tuples cannot cross read, write, or destroy ==\n'

parallel_runner_a=$scratch/parallel-runner-6101
parallel_runner_b=$scratch/parallel-runner-6102
parallel_nsc_a=$scratch/parallel-nsc-6101
parallel_nsc_b=$scratch/parallel-nsc-6102

parallel_run() {
  local run_id=${1:?run id required} runner=${2:?runner required} nsc_root=${3:?nsc root required}
  prepare_run "$run_id" ditto-build-local "$runner" "$nsc_root"
  run_orchestrator ssh-delay
}

parallel_run 6101 "$parallel_runner_a" "$parallel_nsc_a" \
  >"$scratch/parallel-a.out" 2>"$scratch/parallel-a.err" &
parallel_pid_a=$!
parallel_run 6102 "$parallel_runner_b" "$parallel_nsc_b" \
  >"$scratch/parallel-b.out" 2>"$scratch/parallel-b.err" &
parallel_pid_b=$!
if ! wait "$parallel_pid_a"; then
  sed -n '1,160p' "$scratch/parallel-a.err" >&2
  fail 'parallel tuple A failed'
fi
if ! wait "$parallel_pid_b"; then
  sed -n '1,160p' "$scratch/parallel-b.err" >&2
  fail 'parallel tuple B failed'
fi

parallel_id_a=$(find "$parallel_nsc_a/instances" -name meta.json -exec jq -r '.cluster_id' {} \;)
parallel_id_b=$(find "$parallel_nsc_b/instances" -name meta.json -exec jq -r '.cluster_id' {} \;)
[[ -n $parallel_id_a && -n $parallel_id_b && $parallel_id_a != "$parallel_id_b" ]] ||
  fail 'parallel tuples did not receive distinct exact cluster IDs'
[[ $(find "$parallel_nsc_a/instances" -name meta.json | wc -l) == 1 &&
  $(find "$parallel_nsc_b/instances" -name meta.json | wc -l) == 1 ]] ||
  fail 'a parallel fake Namespace root observed another tuple instance'

assert_parallel_log_scope() {
  local log=${1:?log required} exact=${2:?exact id required} other=${3:?other id required}
  awk -v exact="$exact" '
    $1 == "instance" && ($2 == "upload" || $2 == "download") && $3 != exact {exit 1}
    $1 == "ssh" && $2 != exact {exit 1}
    $1 == "destroy" && $3 != exact {exit 1}
  ' "$log" || fail "$log contains a cross-tuple read/write/destroy selector"
  ! grep -Fq -- "$other" "$log" || fail "$log mentions the other tuple cluster ID"
  [[ $(grep -Ec "^destroy --force ${exact} " "$log") == 1 ]] ||
    fail "$log does not destroy its exact tuple exactly once"
}

assert_parallel_log_scope "$parallel_nsc_a/log" "$parallel_id_a" "$parallel_id_b"
assert_parallel_log_scope "$parallel_nsc_b/log" "$parallel_id_b" "$parallel_id_a"
jq -e --arg run 6101 '.owner.runId == $run' \
  "$parallel_nsc_a/instances/$parallel_id_a/fs/run/diene-ci/receipt.json" >/dev/null ||
  fail 'parallel tuple A read or received another tuple receipt'
jq -e --arg run 6102 '.owner.runId == $run' \
  "$parallel_nsc_b/instances/$parallel_id_b/fs/run/diene-ci/receipt.json" >/dev/null ||
  fail 'parallel tuple B read or received another tuple receipt'
jq -e --arg cluster "$parallel_id_a" --arg run 6101 \
  '.workflow.runId == $run and .instance.clusterId == $cluster' \
  "$parallel_runner_a/diene-environment-report.v1.json" >/dev/null ||
  fail 'parallel tuple A report crossed identity'
jq -e --arg cluster "$parallel_id_b" --arg run 6102 \
  '.workflow.runId == $run and .instance.clusterId == $cluster' \
  "$parallel_runner_b/diene-environment-report.v1.json" >/dev/null ||
  fail 'parallel tuple B report crossed identity'
[[ ! -e $parallel_nsc_a/instances/$parallel_id_a/live &&
  ! -e $parallel_nsc_b/instances/$parallel_id_b/live ]] ||
  fail 'a parallel exact instance survived cleanup'
ok 'parallel tuples have distinct IDs, receipts, reports, roots, and exact cleanup selectors'

printf '== interim iptables-nft host/pod enforcement ==\n'

policy_tools=$scratch/policy-tools
policy_state=$scratch/policy-tables
install -d -m 0700 "$policy_tools" "$policy_state"

cat >"$policy_tools/iptables4" <<'TABLE'
#!/usr/bin/env bash
set -euo pipefail
family=4
[[ $(basename -- "$0") != *6 ]] || family=6
state=${FAKE_TABLE_STATE:?}/$family
install -d -m 0700 "$state"
printf '%q ' "$@" >>"${FAKE_TABLE_LOG:?}"
printf '\n' >>"${FAKE_TABLE_LOG:?}"
signature="$family $*"
if [[ -n ${FAKE_TABLE_FAIL_REGEX:-} && $signature =~ ${FAKE_TABLE_FAIL_REGEX} ]]; then exit 88; fi
if [[ ${1:-} == --version ]]; then
  printf 'iptables v1.8.13 (nf_tables)\n'
  exit 0
fi
if [[ ${1:-} == -w && ${2:-} == 5 ]]; then shift 2; fi
operation=${1:-}
shift || true
case $operation in
  -N)
    chain=${1:?}
    [[ ! -e $state/chain-$chain ]] || exit 1
    : >"$state/chain-$chain"
    ;;
  -A)
    chain=${1:?}
    shift
    [[ -f $state/chain-$chain ]] || exit 1
    printf -- '-A %s' "$chain" >>"$state/chain-$chain"
    printf ' %q' "$@" >>"$state/chain-$chain"
    printf '\n' >>"$state/chain-$chain"
    ;;
  -I)
    base=${1:?}
    position=${2:?}
    jump=${3:?}
    chain=${4:?}
    [[ $position == 1 && $jump == -j && ($base == OUTPUT || $base == FORWARD) ]] || exit 1
    printf -- '-A %s -j %s\n' "$base" "$chain" >>"$state/hooks-$base"
    ;;
  -D)
    base=${1:?}
    jump=${2:?}
    chain=${3:?}
    [[ $jump == -j && ($base == OUTPUT || $base == FORWARD) ]] || exit 1
    hooks=$state/hooks-$base
    [[ -f $hooks ]] || exit 1
    awk -v expected="-A $base -j $chain" '$0 != expected' "$hooks" >"$hooks.tmp"
    mv "$hooks.tmp" "$hooks"
    ;;
  -F)
    chain=${1:?}
    [[ -f $state/chain-$chain ]] || exit 1
    : >"$state/chain-$chain"
    ;;
  -X)
    chain=${1:?}
    [[ -f $state/chain-$chain ]] || exit 1
    rm -f -- "$state/chain-$chain"
    ;;
  -S)
    selected=${1:-}
    if [[ $selected == OUTPUT || $selected == FORWARD ]]; then
      [[ ! -f $state/hooks-$selected ]] || sed -n '1,200p' "$state/hooks-$selected"
      exit 0
    fi
    [[ -n $selected && -f $state/chain-$selected ]] || exit 1
    sed -n '1,240p' "$state/chain-$selected"
    ;;
  *) exit 127 ;;
esac
TABLE
cp "$policy_tools/iptables4" "$policy_tools/iptables6"
chmod 0755 "$policy_tools/iptables4" "$policy_tools/iptables6"

cat >"$policy_tools/ip" <<'IP'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  '-o -4 route show')
    printf '%s\n' '10.0.0.0/30 dev eth0 proto kernel' '10.142.0.0/16 dev cni0' 'default via 10.0.0.1 dev eth0'
    ;;
  '-o -6 route show')
    printf '%s\n' 'fd00:142::/64 dev cni0' 'fe80::/64 dev eth0' 'default via fe80::1 dev eth0'
    ;;
  *) exit 127 ;;
esac
IP

cat >"$policy_tools/kubectl" <<'KUBECTL'
#!/usr/bin/env bash
set -euo pipefail
printf '%q ' "$@" >>"${FAKE_KUBECTL_LOG:?}"
printf '\n' >>"${FAKE_KUBECTL_LOG:?}"
case "$*" in
  'get nodes -o json')
    jq -n '{items:[{spec:{podCIDR:"10.142.0.0/16",podCIDRs:["10.142.0.0/16","fd00:142::/64"]},
      status:{conditions:[{type:"Ready",status:"True"}],capacity:{cpu:"16",memory:"32Gi"}}}]}'
    ;;
  'get ingress -A -o json' | 'get gateway -A -o json') printf '%s\n' '{"items":[]}' ;;
  'get service -A -o json')
    printf '%s\n' '{"items":[{"metadata":{"name":"kgateway"},"spec":{"type":"ClusterIP","externalIPs":[]}}]}'
    ;;
  *) exit 127 ;;
esac
KUBECTL

cat >"$policy_tools/resolver" <<'RESOLVER'
#!/usr/bin/env bash
set -euo pipefail
family=${1:?}
dns=${2:?}
[[ $dns == api.example.test || $dns == vendor.example.test || $dns == ghcr.io ]] || exit 1
case $family in
  ipv4) printf '%s\n' "${FAKE_RESOLVER_IPV4:-203.0.113.8}" ;;
  ipv6) printf '%s\n' '2001:db8::8' ;;
  *) exit 127 ;;
esac
RESOLVER
chmod 0755 "$policy_tools/ip" "$policy_tools/kubectl" "$policy_tools/resolver"

policy_table_log=$scratch/policy-table.log
policy_kubectl_log=$scratch/policy-kubectl.log
policy_l7_log=$scratch/policy-l7.log
policy_probe_log=$scratch/policy-probe.log
: >"$policy_table_log"
: >"$policy_kubectl_log"
: >"$policy_l7_log"
: >"$policy_probe_log"

prepare_run 7001
policy_evidence=$scratch/policy-evidence
install -d -m 0700 "$policy_evidence"
jq -n '{network:{serviceCidrs:["10.143.0.0/16"]}}' >"$policy_evidence/preflight.json"
(
  cd -- "$work"
  # shellcheck source=/dev/null
  source ./scripts/ci/environment-lib.sh
  diene_validate_inputs
  export DIENE_NSC_CLUSTER_ID=cluster-policy-7001
  export DIENE_PREFLIGHT_EVIDENCE="$policy_evidence/preflight.json"
  export DIENE_KUBECTL_BIN="$policy_tools/kubectl"
  export DIENE_IPTABLES_BIN="$policy_tools/iptables4"
  export DIENE_IP6TABLES_BIN="$policy_tools/iptables6"
  export DIENE_EGRESS_RESOLVER_BIN="$policy_tools/resolver"
  export FAKE_TABLE_STATE="$policy_state" FAKE_TABLE_LOG="$policy_table_log"
  export FAKE_KUBECTL_LOG="$policy_kubectl_log" FAKE_L7_LOG="$policy_l7_log"
  export FAKE_PROBE_LOG="$policy_probe_log" SSH_CONNECTION='192.0.2.10 4242 10.0.0.2 22'
  export PATH="$policy_tools:$PATH"
  diene_prepare_egress_contract "$policy_evidence/contract.json"
  diene_resolve_egress_contract "$policy_evidence/contract.json" "$policy_evidence/resolved.json"
  diene_preflow_start
  diene_apply_interim_policy "$policy_evidence/resolved.json" "$policy_evidence/policy.json" \
    "$policy_evidence/l7.json"
  diene_verify_hostile_egress "$policy_evidence/hostile-probes.json"
  diene_verify_endpoint_law "$policy_evidence/endpoint.json"
  diene_remove_interim_policy
) >"$scratch/policy.out" 2>"$scratch/policy.err" || {
  sed -n '1,200p' "$scratch/policy.err" >&2
  fail 'the measured interim policy happy path failed'
}

jq -e '.mode == "allowlist" and .profileId == "ditto-build-local-v1" and
  .platformStatus == "platform per-instance policy pending (support ask #4)" and
  (.entries | length) == 1 and .entries[0].dns == "api.example.test" and
  .entries[0].sni == "api.example.test" and .entries[0].port == 443 and
  .entries[0].methods == ["GET","POST"]' "$policy_evidence/contract.json" >/dev/null ||
  fail 'connected egress contract lost the exact support stamp or DNS/SNI/port/method boundary'
jq -e '.resolvedEntries[0].addresses.ipv4 == ["203.0.113.8"] and
  .resolvedEntries[0].addresses.ipv6 == ["2001:db8::8"]' "$policy_evidence/resolved.json" >/dev/null ||
  fail 'resolver output was not bound into the policy contract'
jq -e '.mechanism == "interim-in-guest-iptables-nft" and .backend == "nf_tables" and
  .platformStatus == "platform per-instance policy pending (support ask #4)" and
  .outputChain != .forwardChain and .ipv6Armed == true and .podCidr == "10.142.0.0/16" and
  .pod6Cidrs == ["fd00:142::/64"] and .serviceCidr == "10.143.0.0/16" and
  .orchestrationException == "exact-ssh-4-tuple" and .applied == true' \
  "$policy_evidence/policy.json" >/dev/null || fail 'policy transcript lacks host/FORWARD/IPv6/exact-SSH facts'
jq -e '.outcome == "Pass" and .defaultDenied == true and .dnsBound == true and
  .sniBound == true and .methodsBound == true' "$policy_evidence/l7.json" >/dev/null ||
  fail 'L7 enforcer did not attest the full declaration boundary'
jq -e 'length == 6 and
  ([.[].id] | sort) == ["host-arbitrary-https-denial","host-metadata-denial",
    "pod-arbitrary-https-denial","pod-dns-denial","pod-metadata-denial",
    "preexisting-flow-transition-denial"] and all(.outcome == "Pass" and .required == true)' \
  "$policy_evidence/hostile-probes.json" >/dev/null || fail 'host and actual-pod hostile proof is incomplete'
jq -e '.outcome == "Pass" and .reasonCode == "LoopbackOnlyNoIngress" and
  .namespaceEndpointUsed == false' "$policy_evidence/endpoint.json" >/dev/null ||
  fail 'loopback/no-ingress endpoint law was not proved'
grep -Fq -- '-I OUTPUT 1 -j' "$policy_table_log" || fail 'host OUTPUT policy was not hooked'
grep -Fq -- '-I FORWARD 1 -j' "$policy_table_log" || fail 'pod FORWARD policy was not hooked'
grep -Eq -- '-p tcp -s 10\.0\.0\.2 -d 192\.0\.2\.10 --sport 22 --dport 4242 -m conntrack --ctstate ESTABLISHED -j ACCEPT' \
  "$policy_table_log" || fail 'SSH exception is not the narrow observed orchestration flow'
grep -Eq -- '-A DIO_[0-9a-f]+ -p tcp -d 203\.0\.113\.8 --dport 443 -j ACCEPT' \
  "$policy_table_log" || fail 'host L3/L4 allowlist did not bind the resolved IPv4 endpoint'
grep -Eq -- '-A DIF_[0-9a-f]+ -s 10\.142\.0\.0/16 -p tcp -d 203\.0\.113\.8 --dport 443 -j ACCEPT' \
  "$policy_table_log" || fail 'pod L3/L4 allowlist did not bind the resolved IPv4 endpoint'
grep -Eq -- '-A DI6O_[0-9a-f]+ -p tcp -d 2001:db8::8 --dport 443 -j ACCEPT' \
  "$policy_table_log" || fail 'host IPv6 allowlist did not bind the resolved endpoint'
grep -Eq -- '-A DI6F_[0-9a-f]+ -s fd00:142::/64 -p tcp -d 2001:db8::8 --dport 443 -j ACCEPT' \
  "$policy_table_log" || fail 'pod IPv6 allowlist did not bind the resolved endpoint'
! grep -Fq -- 'ESTABLISHED,RELATED' "$policy_table_log" || fail 'a blanket established-flow exemption was installed'
! grep -Eq -- '0\.0\.0\.0/0|::/0' "$policy_table_log" || fail 'an unrestricted L3 route was allowed'
! grep -Fq -- '-d 10.0.0.0/30' "$policy_table_log" ||
  fail 'an unrelated connected IPv4 LAN was accepted'
! grep -Fq -- '-d fe80::/64' "$policy_table_log" ||
  fail 'an unrelated connected IPv6 LAN was accepted'
for scope in preexisting-open preexisting-transition host pod; do
  grep -Fq -- "--scope $scope" "$policy_probe_log" || fail "hostile probe scope $scope was not exercised"
done
grep -Fq -- "--image $CANARY_IMAGE" "$policy_probe_log" || fail 'pod probe did not use the immutable canary image'
grep -Fq -- 'apply --profile ditto-build-local-v1' "$policy_l7_log" || fail 'L7 policy did not arm'
grep -Fq -- 'remove --profile ditto-build-local-v1' "$policy_l7_log" || fail 'L7 policy did not remove'
output_chain=$(jq -r '.outputChain' "$policy_evidence/policy.json")
forward_chain=$(jq -r '.forwardChain' "$policy_evidence/policy.json")
output6_chain=$(jq -r '.output6Chain' "$policy_evidence/policy.json")
forward6_chain=$(jq -r '.forward6Chain' "$policy_evidence/policy.json")
for chain in "$output_chain" "$forward_chain" "$output6_chain" "$forward6_chain"; do
  [[ ! -e $policy_state/4/chain-$chain && ! -e $policy_state/6/chain-$chain ]] ||
    fail "receipt-scoped policy chain $chain survived removal"
done
for family in 4 6; do
  for hook in OUTPUT FORWARD; do
    [[ ! -s $policy_state/$family/hooks-$hook ]] || fail "IPv$family $hook hook survived removal"
  done
done
if rg -n '(^|[[:space:]])nsc[[:space:]]+egress|egress[[:space:]]+policy[[:space:]]+(create|update)' \
  "$template_root/scripts/ci" "$template_root/.github/workflows" >"$scratch/tenant-policy"; then
  sed -n '1,120p' "$scratch/tenant-policy" >&2
  fail 'active code mutates a tenant-wide Namespace egress policy'
fi
ok 'iptables-nft enforces exact host/pod IPv4+IPv6 rules, hostile probes, narrow SSH, and full removal'

printf '== partial policy transactions roll back completely ==\n'

assert_policy_state_absent() {
  local state=${1:?state required} label=${2:?label required}
  ! find "$state" -type f -name 'chain-*' -print -quit | grep -q . ||
    fail "$label left a receipt-scoped chain"
  while IFS= read -r hook; do
    [[ ! -s $hook ]] || fail "$label left a receipt-scoped hook"
  done < <(find "$state" -type f -name 'hooks-*' -print)
}

policy_failure_case() {
  local run_id=${1:?run id required} label=${2:?label required} table_regex=${3-}
  local l7_complete=${4:-true} expected=${5:-InterimPolicyUnavailable}
  prepare_run "$run_id"
  local state=$scratch/policy-failure-$label tables=$scratch/policy-failure-$label.log
  local l7_log=$scratch/policy-failure-$label-l7.log evidence=$scratch/policy-failure-$label-evidence
  install -d -m 0700 "$state" "$evidence"
  : >"$tables"
  : >"$l7_log"
  jq -n '{network:{serviceCidrs:["10.143.0.0/16"]}}' >"$evidence/preflight.json"
  if (
    cd -- "$work"
    # shellcheck source=/dev/null
    source ./scripts/ci/environment-lib.sh
    diene_validate_inputs
    export DIENE_NSC_CLUSTER_ID="cluster-$label-$run_id"
    export DIENE_PREFLIGHT_EVIDENCE="$evidence/preflight.json"
    export DIENE_KUBECTL_BIN="$policy_tools/kubectl"
    export DIENE_IPTABLES_BIN="$policy_tools/iptables4"
    export DIENE_IP6TABLES_BIN="$policy_tools/iptables6"
    export DIENE_EGRESS_RESOLVER_BIN="$policy_tools/resolver"
    export FAKE_TABLE_STATE="$state" FAKE_TABLE_LOG="$tables"
    export FAKE_TABLE_FAIL_REGEX="$table_regex" FAKE_KUBECTL_LOG="$policy_kubectl_log"
    export FAKE_L7_LOG="$l7_log" FAKE_L7_COMPLETE="$l7_complete"
    export SSH_CONNECTION='192.0.2.10 4242 10.0.0.2 22'
    diene_prepare_egress_contract "$evidence/contract.json"
    diene_resolve_egress_contract "$evidence/contract.json" "$evidence/resolved.json"
    diene_apply_interim_policy "$evidence/resolved.json" "$evidence/policy.json" "$evidence/l7.json"
  ) >"$scratch/policy-failure-$label.out" 2>"$scratch/policy-failure-$label.err"; then
    fail "$label partial policy unexpectedly succeeded"
  fi
  grep -Fq -- "$expected" "$scratch/policy-failure-$label.err" || {
    sed -n '1,200p' "$scratch/policy-failure-$label.err" >&2
    fail "$label did not retain $expected"
  }
  assert_policy_state_absent "$state" "$label"
  POLICY_FAILURE_TABLE_LOG=$tables
  POLICY_FAILURE_L7_LOG=$l7_log
  ok "$label failure proves complete receipt-scoped rollback"
}

policy_failure_case 7101 partial-ipv4 '^4 -w 5 -I FORWARD'
grep -Fq -- '-D OUTPUT -j DIO_' "$POLICY_FAILURE_TABLE_LOG" ||
  fail 'partial IPv4 rollback did not remove the first installed hook'

policy_failure_case 7102 partial-ipv6 '^6 -w 5 -I FORWARD'
grep -Fq -- '-D OUTPUT -j DI6O_' "$POLICY_FAILURE_TABLE_LOG" ||
  fail 'partial IPv6 rollback did not remove the first IPv6 hook'
grep -Fq -- '-D OUTPUT -j DIO_' "$POLICY_FAILURE_TABLE_LOG" ||
  fail 'partial IPv6 rollback did not also remove the complete IPv4 transaction'

policy_failure_case 7103 l7-attestation '' false ConnectedEgressInterfaceUnavailable
grep -Fq -- 'apply --profile ditto-build-local-v1' "$POLICY_FAILURE_L7_LOG" ||
  fail 'L7 failure injection never reached the apply boundary'
grep -Fq -- 'remove --profile ditto-build-local-v1' "$POLICY_FAILURE_L7_LOG" ||
  fail 'L7 failure rollback did not remove the attempted enforcer state'
ok 'partial IPv4, partial IPv6, and L7 failures leave no receipt-scoped hook or chain'

printf '== resolver, hostile probe, and vendor broker fail closed ==\n'

prepare_run 7110
if (
  cd -- "$work"
  # shellcheck source=/dev/null
  source ./scripts/ci/environment-lib.sh
  diene_validate_inputs
  diene_prepare_egress_contract "$scratch/resolver-contract.json"
  export DIENE_EGRESS_RESOLVER_BIN="$policy_tools/resolver" FAKE_RESOLVER_IPV4=not-an-ip
  diene_resolve_egress_contract "$scratch/resolver-contract.json" "$scratch/resolver-invalid.json"
) >"$scratch/resolver-invalid.out" 2>"$scratch/resolver-invalid.err"; then
  fail 'an invalid resolver result was accepted'
fi
assert_contains "$scratch/resolver-invalid.err" ConnectedEgressInterfaceUnavailable
ok 'invalid resolved addresses refuse before policy activation'

prepare_run 7111
probe_failure_log=$scratch/probe-failure.log
: >"$probe_failure_log"
if (
  cd -- "$work"
  # shellcheck source=/dev/null
  source ./scripts/ci/environment-lib.sh
  diene_validate_inputs
  export DIENE_NSC_CLUSTER_ID=cluster-probe-7111 DIENE_PREFLOW_ADAPTER=true
  export FAKE_PROBE_LOG="$probe_failure_log" FAKE_PROBE_FAIL_SCOPE=pod
  diene_verify_hostile_egress "$scratch/probe-invalid.json"
) >"$scratch/probe-invalid.out" 2>"$scratch/probe-invalid.err"; then
  fail 'a failing actual-pod hostile probe was accepted'
fi
assert_contains "$scratch/probe-invalid.err" InterimPolicyUnavailable
grep -Fq -- '--scope host' "$probe_failure_log" || fail 'host negative probe was skipped before pod failure'
grep -Fq -- '--scope pod' "$probe_failure_log" || fail 'actual-pod failure injection was not exercised'
[[ ! -e $scratch/probe-invalid.json ]] || fail 'a failing hostile probe emitted passing evidence'
ok 'hostile actual-pod metadata/arbitrary-HTTPS/DNS proof is mandatory'

prepare_run 7112 ditto-vendor
vendor_contract=$scratch/vendor-contract.json
(
  cd -- "$work"
  # shellcheck source=/dev/null
  source ./scripts/ci/environment-lib.sh
  diene_validate_inputs
  diene_prepare_egress_contract "$vendor_contract"
) >"$scratch/vendor-contract.out" 2>"$scratch/vendor-contract.err" || {
  sed -n '1,120p' "$scratch/vendor-contract.err" >&2
  fail 'declared vendor broker/egress contract failed'
}
jq -e '.profileId == "ditto-vendor-v1" and .mode == "allowlist" and
  .platformStatus == "platform per-instance policy pending (support ask #4)" and
  .entries == [{dns:"vendor.example.test",sni:"vendor.example.test",port:443,
    methods:["GET","POST","DELETE"]}]' "$vendor_contract" >/dev/null ||
  fail 'vendor contract widened or changed its declared egress boundary'

broker_log=$scratch/broker-failure.log
: >"$broker_log"
if (cd -- "$work" && FAKE_BROKER_LOG="$broker_log" FAKE_BROKER_FAIL_COMMAND=issue \
  ./.diene/ci/vendor-broker issue --action demo-vendor --output "$scratch/vendor-secret" \
    --evidence "$scratch/vendor-broker-evidence.json"); then
  fail 'the fake broker failure injection unexpectedly issued a credential'
fi
[[ ! -e $scratch/vendor-secret ]] || fail 'failed broker issue left credential bytes'
grep -Fq 'diene_die VendorBrokerInterfaceUnavailable' "$script_dir/environment-vendor-run.sh" ||
  fail 'the vendor driver does not fail closed on broker issue'
# The quoted shell expression is intentionally matched literally.
# shellcheck disable=SC2016
grep -Fq 'if ! "$broker" revoke' "$script_dir/environment-vendor-run.sh" ||
  fail 'the vendor driver does not make broker revocation cleanup-blocking'
ok 'vendor broker issue/revoke and exact vendor allowlist remain fail closed'

printf '\nenvironment contract checkpoint: PASS (%d checks)\n' "$passed"
