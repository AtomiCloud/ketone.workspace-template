#!/usr/bin/env bash
# Fully local proof of the diene-ci-k3d/v1 compatibility contract. The fake
# Namespace CLI implements only the measured nsc v0.0.532 lifecycle surface;
# every other verb or argument is a test failure by construction.
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
