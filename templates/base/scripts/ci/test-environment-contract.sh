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
nix_shell_home=$scratch/nix-shell-home
cleanup_scratch() {
  chmod -R u+rwX "$scratch" 2>/dev/null || true
  rm -r -- "$scratch"
}
trap cleanup_scratch EXIT
install -d -m 0700 "$nix_shell_home"

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
expect_refusal_message() {
  local reason=${1:?reason required} message=${2:?message required}
  shift 2
  if "$@" >"$scratch/stdout" 2>"$scratch/stderr"; then
    fail "expected $reason refusal but the command succeeded"
  fi
  grep -Fxq -- "$reason: $message" "$scratch/stderr" || {
    sed -n '1,160p' "$scratch/stderr" >&2
    fail "missing exact $reason evidence: $message"
  }
  ok "refuses $reason ($message)"
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

for command in jq yq check-jsonschema sha256sum tar grep sed awk find timeout rg base64 stat nix cmp readlink diff; do
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
  "$work/.github/workflows" \
  "$work/.diene/ci/fixtures/demo" "$work/.diene/ci/fixtures/bootstrap-fleet-independence-v1"
cp -R "$template_root/schemas/ci" "$work/schemas/"
cp "$script_dir"/environment-*.sh "$work/scripts/ci/"
cp "$template_root/.github/workflows/⚡reusable-environment-k3d.yaml" "$work/.github/workflows/"
chmod 0755 "$work/scripts/ci"/*.sh

# The production pins remain asserted from template_root below. The synthetic
# lifecycle copy uses tiny deterministic stand-ins so every fake Namespace run
# exercises the real fetch/length/digest/publish/upload rail without a network
# dependency or a repeated 73 MB transfer.
guest_nix_fixture_dir=$scratch/guest-nix-fixture
install -d -m 0700 "$guest_nix_fixture_dir"
printf '%s\n' '#!/bin/sh' 'printf provenance-witness-only' \
  >"$guest_nix_fixture_dir/guest-nix-bootstrap.sh"
printf '%s\n' 'synthetic-direct-installer-payload' \
  >"$guest_nix_fixture_dir/guest-nix-installer"
chmod 0600 "$guest_nix_fixture_dir/guest-nix-bootstrap.sh" \
  "$guest_nix_fixture_dir/guest-nix-installer"
guest_nix_fixture_installer_digest="sha256:$(sha256sum "$guest_nix_fixture_dir/guest-nix-bootstrap.sh" | awk '{print $1}')"
guest_nix_fixture_payload_digest="sha256:$(sha256sum "$guest_nix_fixture_dir/guest-nix-installer" | awk '{print $1}')"
guest_nix_fixture_installer_bytes=$(wc -c <"$guest_nix_fixture_dir/guest-nix-bootstrap.sh")
guest_nix_fixture_payload_bytes=$(wc -c <"$guest_nix_fixture_dir/guest-nix-installer")
sed -i \
  -e "s|^DIENE_GUEST_NIX_INSTALLER_DIGEST=.*|DIENE_GUEST_NIX_INSTALLER_DIGEST=$guest_nix_fixture_installer_digest|" \
  -e "s|^DIENE_GUEST_NIX_INSTALLER_BYTES=.*|DIENE_GUEST_NIX_INSTALLER_BYTES=$guest_nix_fixture_installer_bytes|" \
  -e "s|^DIENE_GUEST_NIX_PAYLOAD_DIGEST=.*|DIENE_GUEST_NIX_PAYLOAD_DIGEST=$guest_nix_fixture_payload_digest|" \
  -e "s|^DIENE_GUEST_NIX_PAYLOAD_BYTES=.*|DIENE_GUEST_NIX_PAYLOAD_BYTES=$guest_nix_fixture_payload_bytes|" \
  "$work/scripts/ci/environment-lib.sh"

fake_guest_nix_curl=$scratch/guest-nix-curl
cat >"$fake_guest_nix_curl" <<'CURL'
#!/usr/bin/env bash
set -euo pipefail
printf '%q ' "$@" >>"${FAKE_GUEST_NIX_CURL_LOG:?}"
printf '\n' >>"$FAKE_GUEST_NIX_CURL_LOG"
output=
url=
while (($#)); do
  case $1 in
    --output) output=${2:?}; shift 2 ;;
    --proto | --proto-redir | --max-redirs | --max-time | --retry) shift 2 ;;
    --fail | --show-error | --silent | --tlsv1.2 | --location) shift ;;
    https://*) url=$1; shift ;;
    *) exit 127 ;;
  esac
done
[[ -n $output && -n $url ]] || exit 127
scenario=${FAKE_GUEST_NIX_FETCH_SCENARIO:-happy}
case $scenario in
  redirect) exit 47 ;;
  transport-fail) exit 22 ;;
esac
case $url in
  */nix-installer-x86_64-linux) source_file=${FAKE_GUEST_NIX_SOURCE_DIR:?}/guest-nix-installer; kind=payload ;;
  */tag/v3.21.9) source_file=${FAKE_GUEST_NIX_SOURCE_DIR:?}/guest-nix-bootstrap.sh; kind=installer ;;
  *) exit 127 ;;
esac
case $scenario in
  "$kind-short") printf x >"$output" ;;
  "$kind-digest")
    cp "$source_file" "$output"
    printf X | dd of="$output" bs=1 seek=0 conv=notrunc status=none
    ;;
  happy) cp "$source_file" "$output" ;;
  *) cp "$source_file" "$output" ;;
esac
CURL
chmod 0755 "$fake_guest_nix_curl"

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
profile=
cluster=
receipt=
transcript=
image=
while (($#)); do
  case $1 in
    --scope) scope=${2:?}; shift 2 ;;
    --profile) profile=${2:?}; shift 2 ;;
    --cluster-id) cluster=${2:?}; shift 2 ;;
    --receipt) receipt=${2:?}; shift 2 ;;
    --transcript) transcript=${2:?}; shift 2 ;;
    --image) image=${2:?}; shift 2 ;;
    *) exit 127 ;;
  esac
done
[[ -n $scope && -n $profile && -n $cluster && -n $receipt && -n $transcript ]] || exit 127
[[ $scope == pod && -n $image || $scope != pod && -z $image ]] || exit 127
[[ $scope != "${FAKE_PROBE_FAIL_SCOPE:-}" ]] || exit 65
[[ $scope != "${FAKE_PROBE_NO_TRANSCRIPT:-}" ]] || exit 0
case $scope in
  preexisting-open) ids='["preexisting-flow-established"]' ;;
  preexisting-transition) ids='["preexisting-flow-transition-denial"]' ;;
  host) ids='["host-metadata-denial","host-arbitrary-https-denial"]' ;;
  pod) ids='["pod-metadata-denial","pod-arbitrary-https-denial","pod-dns-denial"]' ;;
  *) exit 127 ;;
esac
install -d -m 0700 "$(dirname -- "$transcript")"
observed_cluster=$cluster
observed_outcome=Pass
observed_drop=
observed_reason=AdapterObservedDenial
observed_required=true
[[ $scope != preexisting-open ]] || observed_reason=AdapterObservedFlowEstablished
if [[ -z ${FAKE_PROBE_MUTATE_SCOPE:-} || $scope == "$FAKE_PROBE_MUTATE_SCOPE" ]]; then
  observed_cluster=${FAKE_PROBE_CLUSTER:-$cluster}
  observed_outcome=${FAKE_PROBE_OUTCOME:-Pass}
  observed_drop=${FAKE_PROBE_DROP_ID:-}
  observed_reason=${FAKE_PROBE_REASON:-$observed_reason}
  observed_required=${FAKE_PROBE_REQUIRED:-true}
fi
jq -n --arg scope "$scope" --arg profile "$profile" \
  --arg cluster "$observed_cluster" --arg receipt "$receipt" \
  --arg outcome "$observed_outcome" --arg drop "$observed_drop" \
  --arg reason "$observed_reason" --argjson required "$observed_required" --argjson ids "$ids" '
  {apiVersion:"diene.atomi.cloud/ci-egress-probe/v1",scope:$scope,profileId:$profile,
   clusterId:$cluster,receiptId:$receipt,
   observations:[$ids[] | select(. != $drop) |
     {id:.,outcome:$outcome,reasonCode:$reason,required:$required}]}
' >"$transcript"
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
  tar -cf "$source_archive" -C "$work" scripts schemas .diene .github
  chmod 0600 "$source_archive"
}
make_source_archive

hostile_archive_dir=$scratch/hostile-source-archives
hostile_archive_stage=$scratch/hostile-source-stage
install -d -m 0700 "$hostile_archive_dir" "$hostile_archive_stage"
printf '%s\n' hostile >"$hostile_archive_stage/payload"
ln -s payload "$hostile_archive_stage/symlink"
ln "$hostile_archive_stage/payload" "$hostile_archive_stage/hardlink"
mkfifo "$hostile_archive_stage/fifo"
for hostile_kind in traversal absolute symlink hardlink fifo device; do
  cp "$source_archive" "$hostile_archive_dir/$hostile_kind.tar"
done
tar -rf "$hostile_archive_dir/traversal.tar" --transform='s|^payload$|../escape|' \
  -C "$hostile_archive_stage" payload 2>/dev/null
tar -rf "$hostile_archive_dir/absolute.tar" --transform='s|^payload$|/absolute|' \
  -C "$hostile_archive_stage" payload 2>/dev/null
tar -rf "$hostile_archive_dir/symlink.tar" -C "$hostile_archive_stage" symlink
tar -rf "$hostile_archive_dir/hardlink.tar" -C "$hostile_archive_stage" payload hardlink
tar -rf "$hostile_archive_dir/fifo.tar" -C "$hostile_archive_stage" fifo
tar -rf "$hostile_archive_dir/device.tar" -P --transform='s|^/dev/null$|device|' /dev/null
chmod 0600 "$hostile_archive_dir"/*.tar

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

# The synthetic fake guest proves only the outer Namespace lifecycle. It
# produces the fixed archive the real orchestrator downloads, and the real
# outer code validates, augments, leakage-scans, schemas, destroys, proves
# absence, and seals it. It is deliberately not inner-driver evidence.
fake_guest=$scratch/fake-guest
cat >"$fake_guest" <<'GUEST'
#!/usr/bin/env bash
set -euo pipefail
state=${1:?guest state required}
cluster_id=${2:?cluster id required}
scenario=${FAKE_NSC_SCENARIO:-happy}
[[ -d $state/source ]] || exit 64
install -d -m 0700 "$state/evidence" "$state/out"
inputs=$state/inputs.json
receipt=$state/receipt.json
evidence=$state/evidence

# The fake guest may not manufacture a runtime version of its own. Its reported
# k3s/Kubernetes facts come from the admitted input, and the feature the outer
# create actually selected must agree with that same admitted minor. Without
# this cross-check the harness could stay green while production created a
# platform-default substrate.
admitted_k3s=$(jq -er '.admittedK3sVersion' "$inputs")
[[ $admitted_k3s =~ ^v([0-9]+)\.([0-9]+)\.[0-9]+\+k3s[0-9]+$ ]] || exit 68
admitted_feature=kubernetes:${BASH_REMATCH[1]}.${BASH_REMATCH[2]}
create_metadata=${FAKE_NSC_ROOT:?}/instances/$cluster_id/meta.json
[[ -f $create_metadata ]] || exit 68
[[ $(jq -er '.kubernetes_feature' "$create_metadata") == "$admitted_feature" ]] || exit 68
[[ $(jq -er '.labels["nsc.kubernetes"]' "$create_metadata") == "${admitted_feature#kubernetes:}" ]] || exit 68

# shellcheck disable=SC1091
source "${TEMPLATE_SCRIPT_DIR:?}/environment-lib.sh"

guest_nix_contract=$(jq -ce '.guestNix' "$inputs")
guest_nix_evidence=$evidence/guest-nix
install -d -m 0700 "$guest_nix_evidence"
guest_nix_identity=$(jq -Scn --argjson contract "$guest_nix_contract" \
  --arg storePath /nix/store/synthetic-determinate/bin/nix \
  --arg storePathDigest sha256:7777777777777777777777777777777777777777777777777777777777777777 \
  --arg installedCopyDigest "$(jq -r '.payloadDigest' <<<"$guest_nix_contract")" '
  $contract + {storePath:$storePath,storePathDigest:$storePathDigest,
    installedCopyDigest:$installedCopyDigest,profileSourced:true}')
printf '%s\n' "$guest_nix_identity" | diene_write_json "$guest_nix_evidence/identity.json"
guest_nix_receipt_digest=$(diene_file_digest "$guest_nix_evidence/identity.json")
guest_nix_preflight=$(jq -c --arg digest "$guest_nix_receipt_digest" \
  '. + {identityReceiptDigest:$digest}' "$guest_nix_evidence/identity.json")

install -d -m 0700 "$evidence/staging/orchestration"
printf '%s\n' 'ESTAB 0 0 10.0.0.2:22 192.0.2.10:4242' \
  >"$evidence/staging/orchestration/ss-observation.txt"
chmod 0600 "$evidence/staging/orchestration/ss-observation.txt"
socket_digest=$(diene_file_digest "$evidence/staging/orchestration/ss-observation.txt")
jq -n --arg digest "$socket_digest" '
  {orchestrationTupleSource:"kernel-ss",orchestrationFlowCount:1,
   orchestrationSelectedRow:"ESTAB 0 0 10.0.0.2:22 192.0.2.10:4242",
   orchestrationObservationDigest:$digest,
   orchestrationObservationArtifact:"orchestration/ss-observation.txt"}' \
  >"$evidence/policy.json"
chmod 0600 "$evidence/policy.json"

jq -n --arg cluster "$cluster_id" --arg k3s "$admitted_k3s" \
  --argjson guestNix "$guest_nix_preflight" '
  {outcome:"Pass",reasonCode:"NamespaceWolfiBuiltInK3sReady",clusterId:$cluster,
   identitySource:"cidfile-metadata-exact-id-ssh",os:{id:"wolfi",version:"rolling",uid:0},
   k3s:{version:$k3s,kubernetesVersion:$k3s,nodeCount:1,
        capacity:{cpu:"16",memory:"32Gi"}},
   network:{podCidrs:["10.142.0.0/16"],serviceCidrs:["10.143.0.0/16"],ipv6Disabled:false,
            namespaceIngress:false,publicBinding:false},storage:{defaultClass:"local-path"},
   policyBackend:{mechanism:"iptables",backend:"nf_tables",version:"iptables v1.8.13 (nf_tables)"},
   guestNix:$guestNix,
   cacheAttached:false,platformStatus:"platform per-instance policy pending (support ask #4)"}' \
  >"$evidence/preflight.json"
chmod 0600 "$evidence/preflight.json"
jq -e --arg digest "$guest_nix_receipt_digest" --slurpfile identity "$guest_nix_evidence/identity.json" '
  (.guestNix | del(.identityReceiptDigest)) == $identity[0] and
  .guestNix.identityReceiptDigest == $digest
' "$evidence/preflight.json" >/dev/null

input_digest=$(diene_sha256_text "$(jq -cS . "$inputs")")
diene_checkpoint_init "$evidence/checkpoint-chain.json" "$input_digest"
diene_checkpoint_append "$evidence/checkpoint-chain.json" instance-preflight Pass \
  "$(diene_file_digest "$evidence/preflight.json")" false
if [[ $scenario == checkpoint-resumed ]]; then
  diene_checkpoint_append "$evidence/checkpoint-chain.json" resumed-readiness Pass \
    "$(diene_sha256_text "$cluster_id|resumed-readiness")" true
  diene_checkpoint_append "$evidence/checkpoint-chain.json" final-clean-pass Pass \
    "$(diene_sha256_text "$cluster_id|final-clean-pass")" false
  diene_checkpoint_seal "$evidence/checkpoint-chain.json" false
elif [[ $scenario == checkpoint-no-final ]]; then
  diene_checkpoint_append "$evidence/checkpoint-chain.json" environment-ready Pass \
    "$(diene_sha256_text "$cluster_id|environment-ready")" false
  diene_checkpoint_seal "$evidence/checkpoint-chain.json" false
else
  diene_checkpoint_append "$evidence/checkpoint-chain.json" final-clean-pass Pass \
    "$(diene_sha256_text "$cluster_id|final-clean-pass")" false
  diene_checkpoint_seal "$evidence/checkpoint-chain.json" true
fi
if [[ $scenario == checkpoint-broken ]]; then
  jq '.checkpoints[0].predecessorDigest = "sha256:9999999999999999999999999999999999999999999999999999999999999999"' \
    "$evidence/checkpoint-chain.json" >"$evidence/checkpoint-chain.json.tmp"
  mv "$evidence/checkpoint-chain.json.tmp" "$evidence/checkpoint-chain.json"
fi

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
    --arg nscVersion "$(jq -r '.nscVersion' "$inputs")" \
    --arg nscArtifactDigest "$(jq -r '.nscArtifactDigest' "$inputs")" \
    --arg nscBinaryDigest "$(jq -r '.nscBinaryDigest' "$inputs")" \
    --arg k3s "$admitted_k3s" \
    --arg vendorDigest "$vendor_digest" --arg vendorOutcome "$vendor_outcome" \
    --arg vendorReason "$vendor_reason" --arg reportOutcome "$report_outcome" --arg reportReason "$report_reason" \
    --argjson required "$required" --slurpfile probes "$evidence/hostile-probes.json" \
    --slurpfile chain "$evidence/checkpoint-chain.json" '
    {apiVersion:"diene.atomi.cloud/ci-vendor-report/v1",repositoryRevision:$revision,
     workflow:{runId:$runId,runAttempt:$runAttempt,workflowRef:$workflow},lane:"ditto-vendor",
     profile:"ditto",buildMode:"build-local",actionId:$action,componentClass:"K9",
     permissionRule:"ditto-vendor-demo",receiptId:$receipt,
     instance:{allocationKey:$allocation,generationKey:$generation,substrateName:("diene-"+$allocation),
       clusterId:$cluster,osId:"wolfi",osVersion:"rolling",k3sVersion:$k3s,
       kubernetesVersion:$k3s,nodeCount:1,capacity:{cpu:"16",memory:"32Gi"}},
     tooling:{gardenLockDigest:$garden,journeyManifestDigest:$vendorDigest,nscVersion:$nscVersion,
       nscArtifactDigest:$nscArtifactDigest,nscBinaryDigest:$nscBinaryDigest,
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
    --arg nscVersion "$(jq -r '.nscVersion' "$inputs")" \
    --arg nscArtifactDigest "$(jq -r '.nscArtifactDigest' "$inputs")" \
    --arg nscBinaryDigest "$(jq -r '.nscBinaryDigest' "$inputs")" \
    --arg k3s "$admitted_k3s" \
    --arg journey "$journey_digest" --arg profileId "$profile_id" --arg reportOutcome "$report_outcome" \
    --arg reportReason "$report_reason" --slurpfile readiness "$evidence/readiness.json" \
    --slurpfile probes "$evidence/hostile-probes.json" --slurpfile chain "$evidence/checkpoint-chain.json" '
    {apiVersion:"diene.atomi.cloud/ci-environment-report/v1",repositoryRevision:$revision,
     workflow:{runId:$runId,runAttempt:$runAttempt,workflowRef:$workflow},lane:$lane,profile:$profile,buildMode:$mode,
     subject:{artifactDigest:$artifact,imageRef:$imageRef,producerWorkflowRef:$workflow},
     instance:{allocationKey:$allocation,generationKey:$generation,substrateName:("diene-"+$allocation),
       clusterId:$cluster,osId:"wolfi",osVersion:"rolling",k3sVersion:$k3s,
       kubernetesVersion:$k3s,nodeCount:1,capacity:{cpu:"16",memory:"32Gi"}},receiptId:$receipt,
     tooling:{gardenLockDigest:$garden,journeyManifestDigest:$journey,nscVersion:$nscVersion,
       nscArtifactDigest:$nscArtifactDigest,nscBinaryDigest:$nscBinaryDigest,
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
elif [[ $scenario == receipt-unpatched ]]; then
  cp "$receipt" "$evidence/ci-receipt.json"
else
  jq '
    .namespace.policy.applied = true |
    .namespace.policy.hostileProbes = "Pass" |
    .cleanup = {outcome:"Pass",reasonCode:"ExactReceiptDestroyed",debt:[]}
  ' "$receipt" >"$evidence/ci-receipt.json"
fi
if [[ $scenario == proof-fifo ]]; then
  mkfifo "$evidence/hostile-fifo"
elif [[ $scenario == proof-unreadable ]]; then
  printf '%s\n' unreadable >"$evidence/hostile-unreadable"
fi
jq -n --arg outcome "$([[ $driver_exit == 0 ]] && printf Pass || printf Fail)" \
  --arg reason "$([[ $driver_exit == 0 ]] && printf DriverCompleted || printf JourneyFailed)" \
  --argjson exitCode "$driver_exit" '{outcome:$outcome,reasonCode:$reason,exitCode:$exitCode}' \
  >"$evidence/driver-status.json"
if [[ $scenario == proof-unreadable ]]; then
  tar --mode=000 -cf "$state/out/proof.tar" -C "$state" evidence
else
  tar -cf "$state/out/proof.tar" -C "$state" evidence
fi
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
fake_guest_nix_pinned_asset_valid() {
  local asset=${1:?asset required} sidecar=${2:?sidecar required}
  local expected_digest=${3:?digest required} expected_bytes=${4:?byte length required}
  local expected_line="${expected_digest#sha256:}  $asset"
  [[ -f $asset && ! -L $asset && -f $sidecar && ! -L $sidecar ]] &&
    [[ $(wc -c <"$asset") == "$expected_bytes" && $(wc -l <"$sidecar") == 1 ]] &&
    [[ $(sha256sum "$asset") == "$expected_line" && $(<"$sidecar") == "$expected_line" ]] &&
    sha256sum -c "$sidecar" >/dev/null 2>&1
}
printf '%q ' "$@" >>"$log"
printf '\n' >>"$log"
command=${1:-}
shift || true
case $command in
  version)
    (($# == 0)) || exit 127
    case $scenario in
      nsc-older) printf 'version v0.0.531\n' ;;
      nsc-newer) printf 'version v0.0.533\n' ;;
      *) printf 'version v0.0.532\n' ;;
    esac
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
    # The measured platform admits the Kubernetes minor only through this one
    # feature selector. Anything else is a platform-default create, which is the
    # exact defect this fake must refuse rather than silently absorb.
    enable_count=0
    enable=
    while (($#)); do
      case $1 in
        --ephemeral) ephemeral=true; shift ;;
        --duration) duration=$2; shift 2 ;;
        --enable=*) enable_count=$((enable_count + 1)); enable=${1#--enable=}; shift ;;
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
    if ((enable_count != 1)) || [[ $enable != kubernetes:1.33 ]]; then
      printf 'fake nsc: create requires exactly one --enable=kubernetes:1.33 (saw %s: %s)\n' \
        "$enable_count" "${enable:-none}" >&2
      exit 68
    fi
    [[ $scenario != create-fail ]] || exit 41
    id="cluster-$(printf '%s' "$unique_tag" | sha256sum | cut -c1-16)"
    instance="$root/instances/$id"
    install -d -m 0700 "$instance/fs"
    jq -n --arg id "$id" --arg tag "$unique_tag" --arg feature "$enable" \
      --arg minor "${enable#kubernetes:}" '
      {cluster_id:$id,unique_tag:$tag,kubernetes_feature:$feature,
       labels:{"nsc.kubernetes":$minor}}' >"$instance/meta.json"
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
    state="$root/instances/$id/fs/run/diene-ci"
    [[ $remote_command == *'sha256sum -c archive-validator.sha256'* &&
      $remote_command == *'./archive-validator.sh source.tar source'* ]] || exit 67
    # Bind the fixed program text, then simulate its ordered side effects. The
    # production string remains the authority; the synthetic guest supplies
    # only outer lifecycle evidence.
    [[ $remote_command == *"${FAKE_GUEST_NIX_GUARD:?}"* &&
      $remote_command == *'uname -m'* &&
      $remote_command == *'guest_nix_pinned_asset_valid guest-nix-bootstrap.sh guest-nix-bootstrap.sha256'* &&
      $remote_command == *'guest_nix_pinned_asset_valid guest-nix-installer guest-nix-installer.sha256'* &&
      $remote_command == *'./guest-nix-installer --version'* &&
      $remote_command == *'installer-version.stderr'* &&
      $remote_command == *"'nix-installer 3.21.9' 21"* &&
      $remote_command == *'guest_nix_exact_output_valid'* &&
      $remote_command == *"NIX_INSTALLER_DIAGNOSTIC_ENDPOINT='' ./guest-nix-installer install linux --no-confirm --init none"* &&
      $remote_command == *'guest_nix_source_profile /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh'* &&
      $remote_command == *'exec /nix/var/nix/profiles/default/bin/nix '* ]] || exit 69
    guest_nix_installer_digest=$(jq -er '.guestNix.installerDigest' "$state/inputs.json")
    guest_nix_installer_bytes=$(jq -er '.guestNix.installerBytes' "$state/inputs.json")
    guest_nix_payload_digest=$(jq -er '.guestNix.payloadDigest' "$state/inputs.json")
    guest_nix_payload_bytes=$(jq -er '.guestNix.payloadBytes' "$state/inputs.json")
    [[ $remote_command == *"guest_nix_installer_digest=${guest_nix_installer_digest}"* &&
      $remote_command == *"guest_nix_installer_bytes=${guest_nix_installer_bytes}"* &&
      $remote_command == *"guest_nix_payload_digest=${guest_nix_payload_digest}"* &&
      $remote_command == *"guest_nix_payload_bytes=${guest_nix_payload_bytes}"* ]] || exit 69
    [[ $remote_command != *'sh ./guest-nix-bootstrap.sh'* &&
      $remote_command != *'guest-nix-bootstrap.sh install'* ]] || exit 69
    if [[ $scenario == remote-source-special ]]; then
      cp "${FAKE_HOSTILE_SOURCE_ARCHIVE:?}" "$state/source.tar"
    fi
    (cd "$state" && sha256sum -c archive-validator.sha256 >/dev/null)
    chmod 0500 "$state/archive-validator.sh"
    "$state/archive-validator.sh" "$state/source.tar" "$state/source"
    event_log=${FAKE_GUEST_NIX_EVENT_LOG:?}
    case $scenario in
      guest-wrong-arch)
        printf '%s\n' arch-refused >>"$event_log"
        printf '%s\n' 'GuestNixInstallerUnsupportedArch: the guest architecture is not the pinned x86_64 target' >&2
        exit 64
        ;;
      guest-preexisting)
        printf '%s\n' preexisting-refused >>"$event_log"
        printf '%s\n' 'GuestNixPreexistingState: the ephemeral guest already contains Nix or /nix state' >&2
        exit 64
        ;;
      guest-upload-bootstrap-tamper) printf X >>"$state/guest-nix-bootstrap.sh" ;;
      guest-upload-payload-tamper) printf X >>"$state/guest-nix-installer" ;;
      guest-upload-sidecar-tamper) printf X >>"$state/guest-nix-installer.sha256" ;;
      guest-upload-bootstrap-pair-tamper)
        printf X | dd of="$state/guest-nix-bootstrap.sh" bs=1 seek=0 conv=notrunc status=none
        (cd "$state" && sha256sum guest-nix-bootstrap.sh >guest-nix-bootstrap.sha256)
        ;;
      guest-upload-payload-pair-tamper)
        printf X | dd of="$state/guest-nix-installer" bs=1 seek=0 conv=notrunc status=none
        (cd "$state" && sha256sum guest-nix-installer >guest-nix-installer.sha256)
        ;;
      guest-upload-payload-symlink)
        cp "$state/guest-nix-installer" "$state/guest-nix-installer.link-target"
        rm "$state/guest-nix-installer"
        ln -s guest-nix-installer.link-target "$state/guest-nix-installer"
        ;;
    esac
    if ! (cd "$state" &&
      fake_guest_nix_pinned_asset_valid guest-nix-bootstrap.sh guest-nix-bootstrap.sha256 \
        "$guest_nix_installer_digest" "$guest_nix_installer_bytes" &&
      fake_guest_nix_pinned_asset_valid guest-nix-installer guest-nix-installer.sha256 \
        "$guest_nix_payload_digest" "$guest_nix_payload_bytes"); then
      printf '%s\n' verify-refused >>"$event_log"
      printf '%s\n' 'GuestNixInstallerUntrusted: an uploaded guest Nix artifact or sidecar changed' >&2
      exit 64
    fi
    printf '%s\n' uploads-verified >>"$event_log"
    printf '%s\n' installer-version-probe >>"$event_log"
    case $scenario in
      guest-wrong-installer-version | guest-empty-installer-version | \
        guest-multiline-installer-version | guest-extra-newline-installer-version | \
        guest-installer-version-stderr)
        printf '%s\n' version-refused >>"$event_log"
        printf '%s\n' 'GuestNixInstallerUntrusted: the pinned installer version output is not exact' >&2
        exit 64
        ;;
    esac
    printf '%s\n' 'installer-version nix-installer 3.21.9' >>"$event_log"
    printf '%s\n' 'installer-argv install linux --no-confirm --init none' >>"$event_log"
    if [[ $scenario == guest-installer-fail ]]; then
      printf '%s\n' 'GuestNixInstallFailed: the pinned guest Nix installer failed' >&2
      exit 64
    fi
    printf '%s\n' profile-source >>"$event_log"
    if [[ $scenario == guest-profile-source-fail ]]; then
      printf '%s\n' 'GuestNixProfileSourceFailed: the exact guest Nix profile returned nonzero while being sourced' >&2
      exit 64
    fi
    if [[ $scenario == guest-toolchain-absent ]]; then
      printf '%s\n' 'GuestNixToolchainAbsent: the instance provides no nix command for the driver entry' >&2
      exit 64
    fi
    printf '%s\n' nix-develop >>"$event_log"
    "${FAKE_GUEST_BIN:?}" "$state" "$id"
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

# The exact fail-closed guest Nix guard the production remote command must
# carry, verbatim. The fake ssh leg refuses any drift from this text and the
# guard is separately executed below, so the diagnostic is proved by behaviour
# rather than by a comment.
guest_nix_guard='command -v nix >/dev/null 2>&1 || { printf "GuestNixToolchainAbsent: %s\n" "the instance provides no nix command for the driver entry" >&2; exit 64; }'

fake_nsc_identity=$scratch/nsc-identity.json
fake_nsc_binary_digest="sha256:$(sha256sum "$fake_nsc" | awk '{print $1}')"
jq -n --arg binary "$fake_nsc_binary_digest" '
  {version:"v0.0.532",
   artifactDigest:"sha256:6666666666666666666666666666666666666666666666666666666666666666",
   binaryDigest:$binary}
' >"$fake_nsc_identity"
chmod 0600 "$fake_nsc_identity"

fake_grep_error=$scratch/grep-error
cat >"$fake_grep_error" <<'GREP'
#!/bin/sh
exit 2
GREP
chmod 0755 "$fake_grep_error"

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
  export DIENE_NSC_IDENTITY_FILE=$fake_nsc_identity
  export FAKE_NSC_ROOT=$nsc_root FAKE_NSC_LOG=$nsc_root/log FAKE_GUEST_BIN=$fake_guest
  export FAKE_GUEST_NIX_GUARD=$guest_nix_guard
  export FAKE_GUEST_NIX_EVENT_LOG=$runner/guest-nix-events.log
  export DIENE_CURL_BIN=$fake_guest_nix_curl FAKE_GUEST_NIX_SOURCE_DIR=$guest_nix_fixture_dir
  export FAKE_GUEST_NIX_CURL_LOG=$runner/guest-nix-curl.log
  export TEMPLATE_SCRIPT_DIR=$work/scripts/ci RUNNER_TEMP=$runner DIENE_SCHEMA_DIR=$work/schemas/ci
  export DIENE_CORE_REPORT=$runner/diene-environment-report.v1.json
  export DIENE_VENDOR_REPORT=$runner/diene-vendor-report.v1.json
  export DIENE_PROOF_BUNDLE=$runner/diene-proof-bundle.tar
  export DIENE_LEAK_CANARY="contract-canary-$run_id" DIENE_NSC_ABSENCE_WAIT_SECONDS=0
  export DIENE_NSC_ABSENCE_INTERVAL_SECONDS=1 GITHUB_OUTPUT=$runner/github-output
  export GITHUB_ENV=$runner/github-env GITHUB_STEP_SUMMARY=$runner/summary
  : >"$FAKE_NSC_LOG"; : >"$FAKE_GUEST_NIX_CURL_LOG"; : >"$FAKE_GUEST_NIX_EVENT_LOG"
  : >"$GITHUB_OUTPUT"; : >"$GITHUB_ENV"; : >"$GITHUB_STEP_SUMMARY"
  unset DIENE_ARTIFACT_PROVENANCE_REF DIENE_ARTIFACT_ATTESTATION_DIGEST
  unset DIENE_CLOSURE_DIGEST DIENE_CLOSURE_BUNDLE_REF
  unset DIENE_CLOSURE_SIGNATURE_BUNDLE_DIGEST DIENE_CLOSURE_TRUST_ROOT_DIGEST
  unset DIENE_NAMESPACE_INGRESS DIENE_PUBLIC_ENDPOINT DIENE_NSC_CACHE_TAG DIENE_CACHE_DIR
  unset DIENE_SEED_IDENTITY DIENE_VENDOR_CREDENTIAL DIENE_NSC_MACHINE_TYPE GITHUB_WORKSPACE
  unset DIENE_PRE_SIT_NEGATIVE_CANARY DIENE_PRE_SIT_FIXTURE_ROOT
  unset FAKE_L7_COMPLETE FAKE_PROBE_FAIL_SCOPE FAKE_PROBE_NO_TRANSCRIPT FAKE_PROBE_DROP_ID
  unset FAKE_PROBE_OUTCOME FAKE_PROBE_CLUSTER FAKE_PROBE_REQUIRED FAKE_PROBE_REASON
  unset FAKE_PROBE_MUTATE_SCOPE
  unset FAKE_L7_LOG FAKE_PROBE_LOG FAKE_BROKER_LOG
  unset FAKE_TABLE_FAIL_REGEX FAKE_RESOLVER_IPV4 FAKE_BROKER_FAIL_COMMAND
  unset FAKE_NODE_POD_CIDRS DIENE_IPV6_DISABLE_PATH DIENE_EVIDENCE_STAGING
  unset FAKE_HOSTILE_SOURCE_ARCHIVE
  unset FAKE_GUEST_NIX_FETCH_SCENARIO
  unset DIENE_GREP_BIN
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
workflow_json=$scratch/reusable-environment-k3d.json
yq -o=json '.' "$workflow" >"$workflow_json"
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

jq -e '
  .jobs as $jobs |
  ["nscloud-ubuntu-26.04-amd64-16x32-with-cache",
   "nscloud-cache-size-50gb",
   "nscloud-cache-tag-atomi-nix-store-cache-ubuntu-26.04-amd64"] as $cached |
  (["environment-ditto-build-local","environment-ditto-target-pull","environment-ditto-vendor"] |
    all(. as $id |
      $jobs[$id]["runs-on"] == $cached and
      $jobs[$id].env.DIENE_ORCHESTRATOR_VENUE == "namespace" and
      $jobs[$id].env.DIENE_ORCHESTRATOR_LABEL == $cached[0])) and
  (["environment-absol","environment-fleet-independence"] |
    all(. as $id |
      $jobs[$id]["runs-on"] == "nscloud-ubuntu-26.04-amd64-16x32" and
      $jobs[$id].env.DIENE_ORCHESTRATOR_VENUE == "namespace" and
      $jobs[$id].env.DIENE_ORCHESTRATOR_LABEL == $jobs[$id]["runs-on"])) and
  (["contract","environment-runner-lifecycle"] |
    all(. as $id |
      $jobs[$id]["runs-on"] == "ubuntu-26.04" and
      $jobs[$id].env.DIENE_ORCHESTRATOR_VENUE == "github-hosted" and
      $jobs[$id].env.DIENE_ORCHESTRATOR_LABEL == $jobs[$id]["runs-on"]))
' "$workflow_json" >/dev/null ||
  fail 'resolved runtime/hosted workflow jobs violate the exact 26.04 cache and venue-label law'
if rg -n 'ubuntu-24\.04' "$template_root/.github/workflows" >"$scratch/hosted-24"; then
  sed -n '1,120p' "$scratch/hosted-24" >&2
  fail 'a workflow still names the retired GitHub-hosted Ubuntu 24.04 venue'
fi
grep -Fq 'platform per-instance policy pending (support ask #4)' \
  "$template_root/scripts/ci/environment-k3d-run.sh" ||
  fail 'the interim platform-policy status is not stamped into workflow evidence'
ok 'each cached, cacheless, and hosted job resolves to its exact 26.04 venue and label'

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

printf '== resolved ci shell owns the production command surface ==\n'

resolve_offline_flake_source() {
  local reference=${1:?flake reference required}
  local revision=${2:?flake revision required}
  local expected_hash=${3:?flake hash required}
  local metadata
  metadata=$(nix flake prefetch --offline --json "$reference") ||
    fail "the pinned flake source is not available offline: $reference"
  jq -er --arg revision "$revision" --arg expectedHash "$expected_hash" '
    select(.locked.rev == $revision and .locked.narHash == $expectedHash) |
    .storePath | select(type == "string" and startswith("/nix/store/"))
  ' <<<"$metadata" || fail "the offline flake source changed identity: $reference"
}

ci_shell_commands=(
  awk base64 basename cat check-jsonschema chmod curl cut date dirname env find
  getent git grep id install ip jq kubectl mktemp mv nc nsc pls pre-commit ps rm
  rg sed sha256sum sleep sort ss stat tar timeout tr wc yq
)
nix_shell_build=()
nix_shell_darwin_eval=()
nix_shell_develop=()
nix_shell_linux_proof=()
nix_shell_darwin_proof=()
nix_shell_proof_has_main=false
if [[ -f $template_root/flake.nix ]]; then
  nix_system=$(nix eval --impure --raw --expr builtins.currentSystem) ||
    fail 'the current Nix system could not be resolved'
  nix_shell_build=(nix build --offline --no-link \
    "$template_root#devShells.$nix_system.ci")
  nix_shell_darwin_eval=(nix eval --offline --raw \
    "$template_root#devShells.aarch64-darwin.ci.drvPath")
  nix_shell_develop=(nix develop --offline --ignore-environment \
    --keep-env-var HOME "$template_root#ci")
  nix_shell_linux_proof=(nix eval --offline --json --apply \
    'shells: {shellNames = builtins.attrNames shells; shellDrvPaths = builtins.mapAttrs (_: shell: shell.drvPath) shells;}' \
    "$template_root#devShells.x86_64-linux")
  nix_shell_darwin_proof=(nix eval --offline --json --apply \
    'shells: {shellNames = builtins.attrNames shells; shellDrvPaths = builtins.mapAttrs (_: shell: shell.drvPath) shells;}' \
    "$template_root#devShells.aarch64-darwin")
  ci_shell_success='the repo-locked ci shell owns every production command and evaluates on Darwin'
else
  nixpkgs_revision=4382ed2b7a6839d4280a9b386db49cbc5907414d
  nixpkgs_hash=sha256-iYL/bixrb6FlHFu/gIuBYzq6c6lM5AAXsXNSWXtIgQc=
  atomipkgs_revision=964cc580004effe73eaf6739fb01d95414f4dd50
  atomipkgs_hash=sha256-mrjPkZJlxoGUGjp1EF57TBIs1wIuGGib1ANvQJHb/2E=
  nixpkgs_source=$(resolve_offline_flake_source \
    "github:NixOS/nixpkgs/$nixpkgs_revision" "$nixpkgs_revision" "$nixpkgs_hash")
  atomipkgs_source=$(resolve_offline_flake_source \
    "github:AtomiCloud/nix-registry/$atomipkgs_revision" \
    "$atomipkgs_revision" "$atomipkgs_hash")

  ci_shell_composition=$scratch/ci-shell-composition.nix
  cat >"$ci_shell_composition" <<'NIX'
{ templateRoot, nixpkgsSource, atomipkgsSource, system ? builtins.currentSystem }:
let
  pkgs = import (builtins.storePath nixpkgsSource) { inherit system; };
  atomi = (builtins.getFlake atomipkgsSource).packages.${system};
  packages = import (templateRoot + "/nix/packages.nix") {
    inherit pkgs atomi;
    pkgs-2605 = pkgs;
    # packages.nix currently takes no packages from this set.  Binding it to
    # the same immutable source keeps this regression offline and bounded.
    pkgs-unstable = pkgs;
  };
  env = import (templateRoot + "/nix/env.nix") { inherit pkgs packages; };
  shells = import (templateRoot + "/nix/shells.nix") {
    inherit pkgs packages env;
    shellHook = "";
  };
  packageName = package: package.pname or package.name;
in
shells // {
  proof = {
    activeMain = map packageName (
      env.main ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux env.mainLinux
    );
    nscName = packages.nsc.name;
    nscOut = packages.nsc.outPath;
    shellDrvPaths = builtins.mapAttrs (_: shell: shell.drvPath) shells;
    shellNames = builtins.attrNames shells;
  };
}
NIX

  nix_composition_args=(
    --argstr templateRoot "$template_root"
    --argstr nixpkgsSource "$nixpkgs_source"
    --argstr atomipkgsSource "$atomipkgs_source"
  )
  nix_shell_build=(nix build --offline --impure --no-link \
    --file "$ci_shell_composition" "${nix_composition_args[@]}" ci)
  nix_shell_darwin_eval=(nix eval --offline --impure --raw \
    --file "$ci_shell_composition" "${nix_composition_args[@]}" \
    --argstr system aarch64-darwin ci.drvPath)
  nix_shell_develop=(nix develop --offline --impure --ignore-environment \
    --keep-env-var HOME --file "$ci_shell_composition" \
    "${nix_composition_args[@]}" ci)
  nix_shell_linux_proof=(nix eval --offline --impure --json \
    --file "$ci_shell_composition" "${nix_composition_args[@]}" \
    --argstr system x86_64-linux proof)
  nix_shell_darwin_proof=(nix eval --offline --impure --json \
    --file "$ci_shell_composition" "${nix_composition_args[@]}" \
    --argstr system aarch64-darwin proof)
  nix_shell_proof_has_main=true
  ci_shell_success='the synthetic offline ci shell for the flake-less template owns every production command and evaluates on Darwin'
fi

validate_shell_proof() {
  local label=${1:?label required} target_system=${2:?system required}
  local strict_main=${3:?strict-main flag required} proof=${4:?proof required}
  local expected_main='[]'
  case $target_system in
    x86_64-linux) expected_main='["git","kubectl","iproute2","glibc"]' ;;
    aarch64-darwin) expected_main='["git","kubectl"]' ;;
    *) fail "unsupported shell-proof system: $target_system" ;;
  esac
  jq -e --argjson strictMain "$strict_main" --argjson expectedMain "$expected_main" '
    .shellNames == ["cd","ci","default","releaser"] and
    (.shellDrvPaths | keys) == ["cd","ci","default","releaser"] and
    ([.shellDrvPaths[] |
      type == "string" and test("^/nix/store/[a-z0-9]{32}-nix-shell\\.drv$")] | all) and
    (if $strictMain then
      .activeMain == $expectedMain and
      .nscName == "nsc-0.0.532" and
      (.nscOut | type == "string" and
        test("^/nix/store/[a-z0-9]{32}-nsc-0\\.0\\.532$"))
    else true end)
  ' <<<"$proof" >/dev/null || fail "$label lost its exact $target_system shell composition"
}

if ! linux_shell_proof=$("${nix_shell_linux_proof[@]}"); then
  fail 'the resolved shell set could not be inspected on x86_64-linux'
fi
if ! darwin_shell_proof=$("${nix_shell_darwin_proof[@]}"); then
  fail 'the resolved shell set could not be inspected on aarch64-darwin'
fi
validate_shell_proof canonical x86_64-linux "$nix_shell_proof_has_main" "$linux_shell_proof"
validate_shell_proof canonical aarch64-darwin "$nix_shell_proof_has_main" "$darwin_shell_proof"

nsc_shell_assertion=$scratch/assert-nsc-shell
cat >"$nsc_shell_assertion" <<'ASSERT_NSC'
#!/usr/bin/env bash
set -euo pipefail
resolved=$(command -v nsc)
[[ ${DIENE_NSC_BIN-} == "$resolved" ]]
[[ $DIENE_NSC_BIN == /nix/store/*-nsc-0.0.532/bin/nsc ]]
nsc_root=${DIENE_NSC_BIN%/bin/nsc}
[[ ${DIENE_NSC_IDENTITY_FILE-} == "$nsc_root/share/diene/nsc-identity.json" ]]
[[ -x $DIENE_NSC_BIN && -r $DIENE_NSC_IDENTITY_FILE ]]
for command_name in git kubectl ip ss getent; do
  command_path=$(command -v "$command_name")
  [[ $command_path == /nix/store/* ]]
done
setup_hook=$nsc_root/nix-support/setup-hook
grep -Fxq "export DIENE_NSC_BIN=$DIENE_NSC_BIN" "$setup_hook"
grep -Fxq "export DIENE_NSC_IDENTITY_FILE=$DIENE_NSC_IDENTITY_FILE" "$setup_hook"
binary_digest="sha256:$(sha256sum "$DIENE_NSC_BIN" | awk '{print $1}')"
jq -e --arg binaryDigest "$binary_digest" '
  .version == "v0.0.532" and
  .artifactDigest == "sha256:b2ec7146c72aa24c95930135259dd6ba8a25fdc4dae2fc92346286ac71bea0fc" and
  .binaryDigest == $binaryDigest
' "$DIENE_NSC_IDENTITY_FILE" >/dev/null
ASSERT_NSC
chmod 0500 "$nsc_shell_assertion"

if ! "${nix_shell_build[@]}" >/dev/null; then
  fail 'the resolved ci shell derivation could not be built offline'
fi
if ! "${nix_shell_darwin_eval[@]}" >"$scratch/ci-shell-darwin-drv"; then
  fail 'the resolved ci shell does not evaluate for aarch64-darwin'
fi
grep -Eq '^/nix/store/[a-z0-9]{32}-[^/]+\.drv$' "$scratch/ci-shell-darwin-drv" ||
  fail 'the aarch64-darwin ci shell evaluation emitted no derivation path'

# This single-quoted program is evaluated by the pure inner Bash, not here.
# shellcheck disable=SC2016
if ! HOME=$nix_shell_home "${nix_shell_develop[@]}" --command bash -ceu '
    assertion=${1:?assertion required}
    shift
    failed=0
    for command_name do
      if ! resolved=$(command -v "$command_name" 2>/dev/null); then
        printf "MISSING: %s\n" "$command_name" >&2
        failed=1
        continue
      fi
      case $resolved in
        /nix/store/*) ;;
        *)
          printf "UNOWNED: %s=%s\n" "$command_name" "$resolved" >&2
          failed=1
          continue
          ;;
      esac
      printf "%s=%s\n" "$command_name" "$resolved"
    done
    "$assertion"
    exit "$failed"
  ' bash "$nsc_shell_assertion" "${ci_shell_commands[@]}" >"$scratch/ci-shell-commands"; then
  fail 'the resolved ci shell does not own the complete production command inventory'
fi
[[ $(wc -l <"$scratch/ci-shell-commands") -eq ${#ci_shell_commands[@]} ]] ||
  fail 'the resolved ci shell command inventory was incomplete'
ok "$ci_shell_success"

grep -Fq 'version = "0.0.532"' "$template_root/nix/packages.nix" ||
  fail 'the declared CI shell does not pin nsc v0.0.532'
grep -Fq 'sha256-suxxRscqokyVkwE1JZ3Wuool/cTa4vySNGKGrHG+oPw=' \
  "$template_root/nix/packages.nix" || fail 'the measured x86_64 nsc release hash is absent'
grep -Fq 'setupHook = pkgs-2605.writeText "diene-nsc-setup-hook"' \
  "$template_root/nix/packages.nix" || fail 'the pinned nsc setup hook is absent'
grep -Fq 'export DIENE_NSC_BIN=@out@/bin/nsc' "$template_root/nix/packages.nix" ||
  fail 'the nsc setup hook does not bind the immutable store executable'
grep -Fq 'export DIENE_NSC_IDENTITY_FILE=@out@/share/diene/nsc-identity.json' \
  "$template_root/nix/packages.nix" || fail 'the nsc setup hook does not bind its identity record'
if rg -n 'inherit[[:space:]]+nsc|^[[:space:]]+nsc$' "$template_root/nix/packages.nix" \
  >"$scratch/inherited-nsc"; then
  sed -n '1,80p' "$scratch/inherited-nsc" >&2
  fail 'packages.nix still permits the channel nsc to replace the measured assignment'
fi
ok 'every declared shell selects the hash-pinned measured Namespace CLI through its setup hook'

source_template_root=$(cd -- "$template_root/../.." && pwd)
generated_fixture_root=$source_template_root/cyan/fixtures/expected
if [[ -f $source_template_root/cyan.yaml && -d $generated_fixture_root &&
  $template_root -ef $source_template_root/templates/base ]]; then
  [[ -n ${ci_shell_composition:-} ]] ||
    fail 'the source fixture proof requires the real flake-less composition expression'
  generated_fixture_count=0
  for fixture_root in "$generated_fixture_root"/*; do
    [[ -d $fixture_root ]] || continue
    for nix_file in env.nix packages.nix shells.nix; do
      [[ -f $fixture_root/nix/$nix_file ]] ||
        fail "generated fixture ${fixture_root##*/} lost nix/$nix_file"
    done
    [[ $(rg -c '^[[:space:]]+(default|ci|cd|releaser) = pkgs\.mkShell \{' \
      "$fixture_root/nix/shells.nix") -eq 4 ]] ||
      fail "generated fixture ${fixture_root##*/} lost one of the four shells"
    [[ $(rg -c 'pkgs\.lib\.optionals pkgs\.stdenv\.hostPlatform\.isLinux mainLinux' \
      "$fixture_root/nix/shells.nix") -eq 4 ]] ||
      fail "generated fixture ${fixture_root##*/} lost Linux-only inputs from a shell"

    fixture_composition_args=(
      --argstr templateRoot "$fixture_root"
      --argstr nixpkgsSource "$nixpkgs_source"
      --argstr atomipkgsSource "$atomipkgs_source"
    )
    if ! fixture_linux_proof=$(nix eval --offline --impure --json \
      --file "$ci_shell_composition" "${fixture_composition_args[@]}" \
      --argstr system x86_64-linux proof); then
      fail "generated fixture ${fixture_root##*/} does not evaluate on x86_64-linux"
    fi
    if ! fixture_darwin_proof=$(nix eval --offline --impure --json \
      --file "$ci_shell_composition" "${fixture_composition_args[@]}" \
      --argstr system aarch64-darwin proof); then
      fail "generated fixture ${fixture_root##*/} does not evaluate on aarch64-darwin"
    fi
    validate_shell_proof "generated fixture ${fixture_root##*/}" x86_64-linux true \
      "$fixture_linux_proof"
    validate_shell_proof "generated fixture ${fixture_root##*/}" aarch64-darwin true \
      "$fixture_darwin_proof"

    for shell_name in default ci cd releaser; do
      HOME=$nix_shell_home \
        nix develop --offline --impure --ignore-environment --keep-env-var HOME \
        --file "$ci_shell_composition" "${fixture_composition_args[@]}" \
        --argstr system x86_64-linux "$shell_name" --command "$nsc_shell_assertion" ||
        fail "generated fixture ${fixture_root##*/} shell $shell_name lost its exact runtime inputs"
    done
    generated_fixture_count=$((generated_fixture_count + 1))
  done
  [[ $generated_fixture_count -eq 9 ]] ||
    fail "expected nine generated fixture proofs, got $generated_fixture_count"
  ok 'all nine generated shapes preserve Linux/Darwin parity, four shells, and pinned nsc identity'
else
  ok 'the consumer shell preserves Linux/Darwin parity, four shells, and pinned nsc identity'
fi

for input in lane repository_id repository_key source_sha garden_lock_digest artifact_digest \
  artifact_provenance_ref artifact_attestation_digest journey_manifest vendor_manifest action_id \
  closure_digest closure_bundle_ref closure_signature_bundle_digest closure_trust_root_digest; do
  grep -Eq "^      ${input}:" "$workflow" || fail "workflow_call input $input is absent"
done
for output in subject_digest receipt_id core_report_digest vendor_report_digest; do
  grep -Eq "^      ${output}:" "$workflow" || fail "workflow_call output $output is absent"
done
ok 'workflow_call retains the complete ratified v1 input/output vocabulary'

core_caller=$template_root/.github/workflows/environment-k3d.yaml
vendor_caller=$template_root/.github/workflows/environment-vendor.yaml
core_caller_json=$scratch/environment-k3d.json
vendor_caller_json=$scratch/environment-vendor.json
yq -o=json '.' "$core_caller" >"$core_caller_json"
yq -o=json '.' "$vendor_caller" >"$vendor_caller_json"

# The GitHub expression is intentionally matched literally.
# shellcheck disable=SC2016
artifact_handoff='diene-artifact-subject-${{ github.run_id }}-${{ github.run_attempt }}'

jq -e --arg subject "$artifact_handoff" '
  .jobs as $jobs |
  {"environment-ditto-build-local":{"contents":"read","id-token":"write"},
   "environment-ditto-target-pull":{"contents":"read","packages":"read","id-token":"write"},
   "environment-absol":{"contents":"read","id-token":"write"},
   "environment-fleet-independence":{"contents":"read"}} as $runtimePermissions |
  (.on | keys | sort) == ["push","schedule","workflow_dispatch"] and
  .on.schedule == [{"cron":"17 3 * * 1"}] and
  (.on.workflow_dispatch.inputs | keys | sort) == ["release_candidate","source_sha"] and
  .permissions == {} and
  (["authorize-runtime","artifact-build","environment-profile-contract"] |
    all(. as $id | $jobs[$id]["runs-on"] == "ubuntu-26.04")) and
  ([ $jobs[] | select(.["runs-on"] == "ubuntu-26.04") ] | length) == 3 and
  $jobs["authorize-runtime"].permissions == {"contents":"read"} and
  $jobs["artifact-build"].needs == "authorize-runtime" and
  $jobs["artifact-build"].permissions ==
    {"contents":"read","packages":"write","id-token":"write"} and
  $jobs["environment-profile-contract"].needs == ["authorize-runtime","artifact-build"] and
  $jobs["environment-profile-contract"].permissions == {"contents":"read"} and
  (["environment-ditto-build-local","environment-ditto-target-pull","environment-absol",
    "environment-fleet-independence"] |
    all(. as $id |
      $jobs[$id].needs == ["authorize-runtime","artifact-build","environment-profile-contract"] and
      $jobs[$id].permissions == $runtimePermissions[$id] and
      $jobs[$id].uses == "./.github/workflows/⚡reusable-environment-k3d.yaml" and
      $jobs[$id].with.journey_manifest == ".diene/ci/journeys.v1.yaml" and
      ($jobs[$id].with | has("vendor_manifest") | not) and
      ($jobs[$id].with | has("action_id") | not))) and
  ($jobs["environment-ditto-target-pull"].with.artifact_provenance_ref |
    contains("needs.artifact-build.outputs.artifact_provenance_ref")) and
  ($jobs["environment-ditto-target-pull"].with.artifact_attestation_digest |
    contains("needs.artifact-build.outputs.artifact_attestation_digest")) and
  (["closure_digest","closure_bundle_ref","closure_signature_bundle_digest",
    "closure_trust_root_digest"] |
    all(. as $field |
      ($jobs["environment-absol"].with[$field] |
        contains("needs.artifact-build.outputs." + $field)))) and
  ($jobs["environment-fleet-independence"].if | contains("schedule")) and
  (["environment-ditto-build-local","environment-ditto-target-pull","environment-absol"] |
    all(. as $id | ($jobs[$id].if | contains("schedule") | not))) and
  ($jobs["environment-absol"].if | contains("inputs.release_candidate == true")) and
  (["environment-ditto-build-local","environment-ditto-target-pull","environment-fleet-independence"] |
    all(. as $id | ($jobs[$id].if | contains("inputs.release_candidate == true") | not))) and
  (([ $jobs["authorize-runtime"].steps[] | .run? // empty ] | join("\n")) as $guard |
    (["=~ ^[0-9a-f]{40}$","git rev-parse --verify","git merge-base --is-ancestor",
      "GITHUB_REPOSITORY_OWNER\" = AtomiCloud","dependabot[bot]",
      "permission\" == write || \"$permission\" == admin",
      "test \"$WORKFLOW_SHA\" = \"$REQUESTED_SHA\""] |
      all(. as $needle | $guard | contains($needle)))) and
  ([ $jobs["artifact-build"].steps[] | select(
    .uses == "actions/upload-artifact@v4" and
    .with.name == $subject and .with.path == "${{ runner.temp }}/artifact.v1.json" and
    .with["if-no-files-found"] == "error" and .with["retention-days"] == 1) ] |
    length) == 1 and
  ($jobs["environment-profile-contract"] as $profile |
    ([ $profile.steps[] | select(
      .uses == "actions/download-artifact@v4" and
      .with.name == $subject and .with.path == "${{ runner.temp }}/subject") ] | length) == 1 and
    ([ $profile.steps[] | select(
      .name == "Validate runtime-free profile, corpus, and parity" and
      (.run | contains("./scripts/ci/environment-profile-contract.sh")) and
      (.run | contains("--validate") | not)) ] | length) == 1 and
    ([ $profile.steps[] | select(
      .uses == "actions/upload-artifact@v4" and .if == "always()" and
      .with.name == ($subject | sub("^diene-artifact-subject";"diene-profile-contract-runtime")) and
      .with.path == "${{ runner.temp }}/diene-profile-contract.json" and
      .with["if-no-files-found"] == "error" and .with["retention-days"] == 7) ] | length) == 1)
' "$core_caller_json" >/dev/null ||
  fail 'the core caller lost exact triggers, permissions, selectors, subject handoff, or profile wiring'

jq -e --arg subject "$artifact_handoff" '
  .jobs as $jobs |
  (.on | keys) == ["workflow_dispatch"] and
  (.on.workflow_dispatch.inputs | keys | sort) == ["action_id","source_sha"] and
  .permissions == {} and
  (["authorize-vendor","artifact-build","environment-profile-contract"] |
    all(. as $id | $jobs[$id]["runs-on"] == "ubuntu-26.04")) and
  ([ $jobs[] | select(.["runs-on"] == "ubuntu-26.04") ] | length) == 3 and
  $jobs["authorize-vendor"].permissions == {"contents":"read"} and
  $jobs["artifact-build"].needs == "authorize-vendor" and
  $jobs["artifact-build"].permissions ==
    {"contents":"read","packages":"write","id-token":"write"} and
  $jobs["environment-profile-contract"].needs == ["authorize-vendor","artifact-build"] and
  $jobs["environment-profile-contract"].permissions == {"contents":"read"} and
  ($jobs["environment-ditto-vendor"].needs ==
    ["authorize-vendor","artifact-build","environment-profile-contract"]) and
  ($jobs["environment-ditto-vendor"].permissions == {"contents":"read","id-token":"write"}) and
  ($jobs["environment-ditto-vendor"].uses == "./.github/workflows/⚡reusable-environment-k3d.yaml") and
  ($jobs["environment-ditto-vendor"].with.vendor_manifest == ".diene/ci/vendors.v1.yaml") and
  ($jobs["environment-ditto-vendor"].with.action_id == "${{ inputs.action_id }}") and
  (($jobs["environment-ditto-vendor"].with | has("journey_manifest")) | not) and
  ($jobs["environment-ditto-vendor"].secrets == "inherit") and
  (([ $jobs["authorize-vendor"].steps[] | .run? // empty ] | join("\n")) as $guard |
    (["=~ ^[0-9a-f]{40}$","git rev-parse --verify","git merge-base --is-ancestor",
      "GITHUB_REPOSITORY_OWNER\" = AtomiCloud","permission\" == write || \"$permission\" == admin",
      "test \"$WORKFLOW_SHA\" = \"$SOURCE_SHA\""] |
      all(. as $needle | $guard | contains($needle)))) and
  ([ $jobs["artifact-build"].steps[] | select(
    .uses == "actions/upload-artifact@v4" and
    .with.name == $subject and .with.path == "${{ runner.temp }}/artifact.v1.json" and
    .with["if-no-files-found"] == "error" and .with["retention-days"] == 1) ] |
    length) == 1 and
  ($jobs["environment-profile-contract"] as $profile |
    ([ $profile.steps[] | select(
      .uses == "actions/download-artifact@v4" and
      .with.name == $subject and .with.path == "${{ runner.temp }}/subject") ] | length) == 1 and
    ([ $profile.steps[] | select(
      .name == "Validate runtime-free profile, corpus, and parity" and
      (.run | contains("./scripts/ci/environment-profile-contract.sh")) and
      (.run | contains("--validate") | not)) ] | length) == 1 and
    ([ $profile.steps[] | select(
      .uses == "actions/upload-artifact@v4" and .if == "always()" and
      .with.name == ($subject | sub("^diene-artifact-subject";"diene-profile-contract-vendor")) and
      .with.path == "${{ runner.temp }}/diene-profile-contract.json" and
      .with["if-no-files-found"] == "error" and .with["retention-days"] == 7) ] | length) == 1)
' "$vendor_caller_json" >/dev/null ||
  fail 'the vendor caller lost exact dispatch, permissions, selectors, subject handoff, or profile wiring'

jq -es '
  ([.[0].jobs | to_entries[] | .value.with.lane? // empty] +
   [.[1].jobs | to_entries[] | .value.with.lane? // empty] | sort) ==
  ["absol","ditto-build-local","ditto-target-pull","ditto-vendor","fleet-independence"]
' "$core_caller_json" "$vendor_caller_json" >/dev/null ||
  fail 'the callers do not dispatch the exact five-lane set once each'

jq -e --arg subject "$artifact_handoff" '
  .jobs as $jobs |
  ["environment-ditto-build-local","environment-ditto-target-pull","environment-ditto-vendor",
   "environment-absol","environment-fleet-independence"] as $runtimeIds |
  {"environment-ditto-build-local":{"contents":"read","id-token":"write"},
   "environment-ditto-target-pull":{"contents":"read","packages":"read","id-token":"write"},
   "environment-ditto-vendor":{"contents":"read","id-token":"write"},
   "environment-absol":{"contents":"read","id-token":"write"},
   "environment-fleet-independence":{"contents":"read"}} as $runtimePermissions |
  ($subject | sub("^diene-artifact-subject-";"diene-namespace-proof-${{ inputs.lane }}-")) as $proof |
  .permissions == {} and
  $jobs.contract.permissions == {"contents":"read"} and
  ([ $jobs.contract.steps[] | select(
    .uses == "actions/download-artifact@v4" and
    .with.name == $subject and .with.path == "${{ runner.temp }}/subject") ] | length) == 1 and
  ($runtimeIds | all(. as $id |
    $jobs[$id].needs == "contract" and
    $jobs[$id].permissions == $runtimePermissions[$id] and
    ([ $jobs[$id].steps[] | select(
      .uses == "actions/download-artifact@v4" and
      .with.name == $subject and .with.path == "${{ runner.temp }}/subject") ] | length) == 1 and
    ([ $jobs[$id].steps[] | select(
      .id == "run" and .["continue-on-error"] == true and
      (.run | contains("./scripts/ci/environment-k3d-run.sh orchestrate"))) ] | length) == 1 and
    ([ $jobs[$id].steps[] | select(
      .id == "lifecycle" and .if == "always()" and
      (.run | contains("./scripts/ci/environment-k3d-run.sh cleanup"))) ] | length) == 1 and
    ([ $jobs[$id].steps[] | select(
      .uses == "actions/upload-artifact@v4" and .if == "always()" and
      .with.name == $proof and .with.path == "${{ runner.temp }}/diene-proof-bundle.tar" and
      .with["if-no-files-found"] == "error" and .with["retention-days"] == 7) ] | length) == 1 and
    ([ $jobs[$id].steps[] | select(
      .if == "always() && (steps.run.outcome != '\''success'\'' || steps.lifecycle.outcome != '\''success'\'')" and
      (.run | contains("exit 1"))) ] | length) == 1)) and
  ($jobs["environment-runner-lifecycle"] as $lifecycle |
    $lifecycle.if == "always()" and $lifecycle.permissions == {"contents":"read"} and
    $lifecycle.needs == ["contract","environment-ditto-build-local","environment-ditto-target-pull",
      "environment-ditto-vendor","environment-absol","environment-fleet-independence"] and
    ([ $lifecycle.steps[] | select(
      .uses == "actions/download-artifact@v4" and
      .with.name == $subject and .with.path == "${{ runner.temp }}/subject") ] | length) == 1 and
    ([ $lifecycle.steps[] | select(
      .uses == "actions/download-artifact@v4" and
      .with.name == $proof and .with.path == "${{ runner.temp }}/namespace-proof") ] | length) == 1 and
    ([ $lifecycle.steps[] | select(
      . as $step |
      $step.name == "Verify the exact terminal lifecycle evidence" and
      (["needs.environment-ditto-build-local.result","needs.environment-ditto-target-pull.result",
        "needs.environment-ditto-vendor.result","needs.environment-absol.result",
        "needs.environment-fleet-independence.result"] |
        all(. as $needle | $step.env.SELECTED_RUNTIME_RESULT | contains($needle))) and
      ($step.run | contains("test \"$SELECTED_RUNTIME_RESULT\" = success")) and
      ($step.run | contains("./scripts/ci/environment-k3d-run.sh lifecycle")) and
      ($step.run | contains("$RUNNER_TEMP/namespace-proof/diene-proof-bundle.tar"))) ] | length) == 1)
' "$workflow_json" >/dev/null ||
  fail 'the reusable subject, runtime proof, permissions, or lifecycle wiring changed'
ok 'caller triggers, blocking needs, permissions, selectors, handoff, trust, and lifecycle wiring are structural'

printf '== executable profile, corpus, and parity contract ==\n'

profile_pls=$scratch/profile-pls
profile_pls_log=$scratch/profile-pls.log
profile_pls_accepted_log=$scratch/profile-pls-accepted.log
cat >"$profile_pls" <<'PLS'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${FAKE_PLS_LOG:?}"
[[ $* != "${FAKE_PLS_FAIL_PAIR:-}" ]] || exit 7
case "$*" in
  'env switch --profile ditto --build-mode build-local' | 'env switch --profile ditto --build-mode target-pull' | 'env switch --profile absol --build-mode build-local')
    printf '%s\n' "$*" >>"${FAKE_PLS_ACCEPTED_LOG:?}"
    ;;
  'env switch --profile absol --build-mode target-pull')
    [[ ${FAKE_PLS_ACCEPT_ALL:-0} == 1 ]] || exit 64
    printf '%s\n' "$*" >>"${FAKE_PLS_ACCEPTED_LOG:?}"
    ;;
  *) exit 127 ;;
esac
PLS
chmod 0755 "$profile_pls"

profile_renderer=$scratch/profile-renderer
profile_renderer_log=$scratch/profile-renderer.log
cat >"$profile_renderer" <<'RENDER'
#!/usr/bin/env bash
set -euo pipefail
[[ ${1:-} == --profile && $# -eq 2 ]] || exit 127
profile=${2:?}
printf '%s\n' "$profile" >>"${FAKE_RENDER_LOG:?}"
[[ $profile != "${FAKE_RENDER_FAIL_PROFILE:-}" ]] || exit 65
jq -n --arg profile "$profile" --arg substrate "${FAKE_RENDER_SUBSTRATE:-k3d}" \
  '{profile:$profile,substrate:$substrate}'
RENDER
chmod 0755 "$profile_renderer"

run_profile_contract() (
  local selected_lock=${1:?lock required} selected_report=${2:?report required}
  local renderer=${3-} accept_all=${4:-0} selected_pls=${5:-$profile_pls}
  cd -- "$work"
  install -d -m 0700 "$scratch/profile-temp"
  export RUNNER_TEMP="$scratch/profile-temp"
  export DIENE_ENVIRONMENT_LOCK="$selected_lock" DIENE_PROFILE_REPORT="$selected_report"
  export DIENE_PLS_BIN="$selected_pls" DIENE_SCHEMA_DIR="$work/schemas/ci"
  export FAKE_PLS_LOG="$profile_pls_log" FAKE_PLS_ACCEPTED_LOG="$profile_pls_accepted_log"
  export FAKE_PLS_ACCEPT_ALL="$accept_all" FAKE_RENDER_LOG="$profile_renderer_log"
  export GITHUB_SHA=$SOURCE_SHA GITHUB_OUTPUT="$scratch/profile-github-output"
  if [[ -n $renderer ]]; then
    export DIENE_PROFILE_RENDER_BIN="$renderer"
  else
    unset DIENE_PROFILE_RENDER_BIN
  fi
  ./scripts/ci/environment-profile-contract.sh
)

render_profile_case() (
  local profile=${1-} renderer=${2-}
  cd -- "$work"
  install -d -m 0700 "$scratch/profile-temp"
  export RUNNER_TEMP="$scratch/profile-temp"
  export DIENE_SCHEMA_DIR="$work/schemas/ci" FAKE_RENDER_LOG="$profile_renderer_log"
  if [[ -n $renderer ]]; then
    export DIENE_PROFILE_RENDER_BIN="$renderer"
  else
    unset DIENE_PROFILE_RENDER_BIN
  fi
  ./scripts/ci/environment-profile-contract.sh --render-profile "$profile"
)

profile_validator=${DIENE_SCHEMA_VALIDATOR_BIN:-check-jsonschema}
profile_output=$scratch/profile-github-output
profile_no_lock=$scratch/profile-no-lock.json
: >"$profile_output"
: >"$profile_pls_log"
: >"$profile_pls_accepted_log"
run_profile_contract "$scratch/absent-environment-lock.json" "$profile_no_lock"
"$profile_validator" --base-uri "file://$work/schemas/ci/" \
  --schemafile "$work/schemas/ci/diene-profile-report-v1.schema.json" "$profile_no_lock" >/dev/null ||
  fail 'the explicit no-lock profile report is not schema-valid'
jq -e '
  .outcome == "NotApplicable" and .reasonCode == "NoDeclaration" and
  .renderedProfiles == [] and .validatedProfiles == [] and
  ([.staticContract[] | .outcome] | length == 6 and all(. == "NotApplicable"))
' "$profile_no_lock" >/dev/null || fail 'an absent environment lock implied profile coverage'
grep -Fxq "profile_report=$profile_no_lock" "$profile_output" ||
  fail 'the no-lock profile report path was not published through GITHUB_OUTPUT'
[[ ! -s $profile_pls_log ]] || fail 'an absent environment lock invoked pls'
ok 'an absent environment lock is explicit schema-valid NotApplicable/NoDeclaration'

profile_lock_directory=$scratch/profile-lock-directory
install -d -m 0700 "$profile_lock_directory"
: >"$profile_pls_log"
expect_refusal_message InputContractInvalid 'environment lock must be a regular file' \
  run_profile_contract "$profile_lock_directory" "$scratch/profile-lock-directory-report.json"
[[ ! -e $scratch/profile-lock-directory-report.json ]] ||
  fail 'a directory environment lock published a profile report'
profile_invalid_lock=$scratch/profile-invalid-lock.json
printf '{invalid json\n' >"$profile_invalid_lock"
expect_refusal_message PreviewManifestSchemaMismatch 'environment lock is not valid JSON' \
  run_profile_contract "$profile_invalid_lock" "$scratch/profile-invalid-lock-report.json"
[[ ! -e $scratch/profile-invalid-lock-report.json ]] ||
  fail 'an invalid-JSON environment lock published a profile report'
[[ ! -s $profile_pls_log ]] || fail 'an invalid environment lock reached pls env switch'
ok 'directory and invalid-JSON lock paths refuse cleanly before pls or report emission'

profile_deferred=$scratch/profile-deferred.json
: >"$profile_output"
: >"$profile_pls_log"
: >"$profile_pls_accepted_log"
expect_refusal_message ProfileRenderInterfaceUnavailable \
  'no ratified runtime-free executable render; set DIENE_PROFILE_RENDER_BIN once Garden publishes one' \
  run_profile_contract \
  "$work/.diene/ci/environment-lock.v1.json" "$profile_deferred"
"$profile_validator" --base-uri "file://$work/schemas/ci/" \
  --schemafile "$work/schemas/ci/diene-profile-report-v1.schema.json" "$profile_deferred" >/dev/null ||
  fail 'the deliberately unavailable renderer report is not schema-valid'
jq -e '
  .outcome == "Fail" and .reasonCode == "ProfileRenderInterfaceUnavailable" and
  ([.staticContract[] | .outcome] | length == 6 and all(. == "Pass")) and
  .staticContract.profileSet.reasonCode == "ExactSixNameSet" and
  .staticContract.substrateParity.reasonCode == "LocalK3dHostedVcluster" and
  .staticContract.retiredNames.reasonCode == "NoRetiredIdentity" and
  .staticContract.consumerPinAliases.reasonCode == "NoAliasFound" and
  .staticContract.oneWriter.reasonCode == "SingleWriterPerObject" and
  .staticContract.buildModeMatrix.reasonCode == "ProfileModePairsValidated" and
  .castformExecutable == {outcome:"Unavailable",reasonCode:"PreviewIdentityUnavailable"} and
  .eeveeExecutable == {outcome:"Unavailable",reasonCode:"PreviewIdentityUnavailable"} and
  .localExecutableRender == {outcome:"Unavailable",reasonCode:"ProfileRenderInterfaceUnavailable"}
' "$profile_deferred" >/dev/null || fail 'the deferred profile rows lost their stable unavailable reasons'
expected_profile_switches=$'env switch --profile ditto --build-mode build-local\nenv switch --profile ditto --build-mode target-pull\nenv switch --profile absol --build-mode build-local'
[[ $(<"$profile_pls_accepted_log") == "$expected_profile_switches" ]] ||
  fail 'the profile gate accepted a pls env switch outside the exact three-pair set'
if ! { [[ $(wc -l <"$profile_pls_log") == 4 ]] &&
  tail -n 1 "$profile_pls_log" | grep -Fxq \
    'env switch --profile absol --build-mode target-pull'; }; then
  fail 'the profile gate did not explicitly test and reject Absol target-pull'
fi
if grep -Eqv '^env switch --profile (ditto|absol) --build-mode (build-local|target-pull)$' \
  "$profile_pls_log"; then
  fail 'the profile gate invoked a pls verb outside env switch'
fi
ok 'the exact three allowed pls env switches pass and Absol target-pull is actively refused'

profile_mutation=$scratch/profile-lock-mutation.json
: >"$profile_pls_log"
: >"$profile_pls_accepted_log"
jq 'del(.profiles.rotom)' "$work/.diene/ci/environment-lock.v1.json" >"$profile_mutation"
expect_refusal_message PreviewManifestSchemaMismatch 'profile set is not the exact six-name set' \
  run_profile_contract \
  "$profile_mutation" "$scratch/profile-five-names.json"
jq '.profiles.porygon = .profiles.rotom | del(.profiles.rotom)' \
  "$work/.diene/ci/environment-lock.v1.json" >"$profile_mutation"
expect_refusal_message PreviewManifestSchemaMismatch 'retired profile identity porygon found' \
  run_profile_contract \
  "$profile_mutation" "$scratch/profile-porygon.json"
jq '.profiles.rotom.substrate = "entei-vcluster"' \
  "$work/.diene/ci/environment-lock.v1.json" >"$profile_mutation"
expect_refusal_message PreviewManifestSchemaMismatch 'substrate parity mismatch' \
  run_profile_contract "$profile_mutation" "$scratch/profile-parity.json"
jq '.profiles.ditto.ref = "refs/heads/main"' "$work/.diene/ci/environment-lock.v1.json" >"$profile_mutation"
expect_refusal_message PreviewManifestSchemaMismatch 'consumer pin alias or operator shape found' \
  run_profile_contract \
  "$profile_mutation" "$scratch/profile-alias.json"
jq '.garden = {kind:"garden",version:"1.0.0"}' \
  "$work/.diene/ci/environment-lock.v1.json" >"$profile_mutation"
expect_refusal_message PreviewManifestSchemaMismatch 'consumer pin alias or operator shape found' \
  run_profile_contract "$profile_mutation" "$scratch/profile-operator-shape.json"
jq '.operator.commitPin = "0000000000000000000000000000000000000000"' \
  "$work/.diene/ci/environment-lock.v1.json" >"$profile_mutation"
expect_refusal_message PreviewManifestSchemaMismatch 'consumer pin alias or operator shape found' \
  run_profile_contract "$profile_mutation" "$scratch/profile-commit-pin.json"
jq '.previewManifest.schemaVersion = "preview-manifest/v2"' \
  "$work/.diene/ci/environment-lock.v1.json" >"$profile_mutation"
expect_refusal_message PreviewManifestSchemaMismatch \
  'imported preview-manifest lock entry is absent or aliased' run_profile_contract \
  "$profile_mutation" "$scratch/profile-manifest-version.json"
jq '.previewManifest.schemaDigest = "sha256:not-a-digest"' \
  "$work/.diene/ci/environment-lock.v1.json" >"$profile_mutation"
expect_refusal_message PreviewManifestSchemaMismatch \
  'imported preview-manifest lock entry is absent or aliased' run_profile_contract \
  "$profile_mutation" "$scratch/profile-manifest-digest.json"
jq '.writers = [
  {soleWriter:{objects:["apps/demo"],secrets:[]}},
  {soleWriter:{objects:["apps/demo"],secrets:[]}}
]' "$work/.diene/ci/environment-lock.v1.json" >"$profile_mutation"
expect_refusal_message PreviewManifestSchemaMismatch 'one-writer ownership is violated' \
  run_profile_contract \
  "$profile_mutation" "$scratch/profile-duplicate-writer.json"
jq '.writers = [{soleWriter:{objects:["apps/demo"],secrets:["apps/demo"]}}]' \
  "$work/.diene/ci/environment-lock.v1.json" >"$profile_mutation"
expect_refusal_message PreviewManifestSchemaMismatch 'one-writer ownership is violated' \
  run_profile_contract "$profile_mutation" "$scratch/profile-writer-overlap.json"
[[ ! -s $profile_pls_log ]] || fail 'a static corpus refusal reached pls env switch'
ok 'every distinct static corpus gate refuses with its exact message before pls'

jq '.writers = [
  {soleWriter:{objects:["apps/demo"],secrets:["secret/demo"]}},
  {soleWriter:{objects:["apps/other"],secrets:["secret/other"]}}
]' "$work/.diene/ci/environment-lock.v1.json" >"$profile_mutation"
: >"$profile_pls_log"
: >"$profile_pls_accepted_log"
expect_refusal_message ProfileRenderInterfaceUnavailable \
  'no ratified runtime-free executable render; set DIENE_PROFILE_RENDER_BIN once Garden publishes one' \
  run_profile_contract "$profile_mutation" "$scratch/profile-distinct-writers.json"
[[ -e $scratch/profile-distinct-writers.json ]] ||
  fail 'distinct sole writers did not pass the one-writer gate and reach report emission'
ok 'distinct sole writers pass the static gate and reach the deferred renderer report'

: >"$profile_pls_log"
: >"$profile_pls_accepted_log"
expect_refusal_message PreviewManifestSchemaMismatch \
  'Absol accepted a non closure-backed build mode' run_profile_contract \
  "$work/.diene/ci/environment-lock.v1.json" "$scratch/profile-bad-mode.json" '' 1
[[ ! -e $scratch/profile-bad-mode.json ]] ||
  fail 'a refused bad-mode corpus published a report'

profile_missing_pls=$scratch/profile-missing-pls
expect_refusal_message DependencyUnavailable "$profile_missing_pls is required" \
  run_profile_contract "$work/.diene/ci/environment-lock.v1.json" \
  "$scratch/profile-missing-pls-report.json" '' 0 "$profile_missing_pls"
[[ ! -e $scratch/profile-missing-pls-report.json ]] ||
  fail 'a missing pls binary published a profile report'

: >"$profile_pls_log"
export FAKE_PLS_FAIL_PAIR='env switch --profile ditto --build-mode target-pull'
expect_refusal_message PreviewManifestSchemaMismatch \
  'Ditto target-pull profile/mode pair was refused' run_profile_contract \
  "$work/.diene/ci/environment-lock.v1.json" "$scratch/profile-pls-rejected.json"
unset FAKE_PLS_FAIL_PAIR
[[ ! -e $scratch/profile-pls-rejected.json ]] ||
  fail 'a refused ratified pls pair published a profile report'
ok 'permissive bad mode, missing pls, and a refused ratified pair all fail with stable evidence and no report'

for hosted_profile in castform eevee; do
  expect_refusal_message PreviewIdentityUnavailable \
    "$hosted_profile executable rendering is outside this node" \
    render_profile_case "$hosted_profile"
  expect_refusal_message PreviewIdentityUnavailable \
    "$hosted_profile executable rendering is outside this node" \
    render_profile_case "$hosted_profile" "$profile_renderer"
done
[[ ! -s $profile_renderer_log ]] || fail 'a hosted preview identity reached the executable renderer'
for local_profile in lapras ditto rotom absol; do
  expect_refusal_message ProfileRenderInterfaceUnavailable \
    'Garden ratifies no runtime-free executable render command' \
    render_profile_case "$local_profile"
done
expect_refusal_message InputContractInvalid 'unknown profile porygon' \
  render_profile_case porygon
expect_refusal_message InputContractInvalid 'unknown profile ' render_profile_case ''

: >"$profile_renderer_log"
for local_profile in lapras ditto rotom absol; do
  render_profile_out=$scratch/profile-render-$local_profile.json
  render_profile_case "$local_profile" "$profile_renderer" >"$render_profile_out"
  jq -e --arg profile "$local_profile" \
    '.profile == $profile and .substrate == "k3d"' "$render_profile_out" >/dev/null ||
    fail "--render-profile did not pass through the $local_profile renderer result"
done
[[ $(<"$profile_renderer_log") == $'lapras\nditto\nrotom\nabsol' ]] ||
  fail '--render-profile invoked the executable renderer with a wrong selector or order'
ok 'all hosted, local, retired, and empty render-profile selectors have stable behavior'

: >"$profile_renderer_log"
export FAKE_RENDER_SUBSTRATE=entei-vcluster
expect_refusal_message ProfileRenderMismatch 'lapras did not render the local k3d contract' \
  run_profile_contract "$work/.diene/ci/environment-lock.v1.json" \
  "$scratch/profile-render-mismatch.json" "$profile_renderer"
unset FAKE_RENDER_SUBSTRATE
[[ ! -e $scratch/profile-render-mismatch.json ]] ||
  fail 'a mismatched executable render published a profile report'
[[ $(<"$profile_renderer_log") == lapras ]] ||
  fail 'render mismatch did not stop at the first local profile'

: >"$profile_renderer_log"
export FAKE_RENDER_FAIL_PROFILE=rotom
expect_refusal_message ProfileRenderInterfaceUnavailable 'rotom executable renderer failed' \
  run_profile_contract "$work/.diene/ci/environment-lock.v1.json" \
  "$scratch/profile-render-failed.json" "$profile_renderer"
unset FAKE_RENDER_FAIL_PROFILE
[[ ! -e $scratch/profile-render-failed.json ]] ||
  fail 'a failing executable renderer published a profile report'
[[ $(<"$profile_renderer_log") == $'lapras\nditto\nrotom' ]] ||
  fail 'a failing executable renderer did not stop at the failing profile'

profile_missing_renderer=$scratch/profile-missing-renderer
expect_refusal_message ProfileRenderInterfaceUnavailable \
  'configured profile renderer is absent or not executable' run_profile_contract \
  "$work/.diene/ci/environment-lock.v1.json" "$scratch/profile-render-missing.json" \
  "$profile_missing_renderer"
[[ ! -e $scratch/profile-render-missing.json ]] ||
  fail 'a missing configured renderer published a profile report'
ok 'mismatched, failing, and missing configured renderers refuse exactly without a report'

: >"$profile_renderer_log"
: >"$profile_pls_log"
: >"$profile_pls_accepted_log"
: >"$profile_output"
profile_rendered=$scratch/profile-rendered.json
run_profile_contract "$work/.diene/ci/environment-lock.v1.json" "$profile_rendered" "$profile_renderer"
jq -e '
  .outcome == "Pass" and .reasonCode == "ContractSatisfied" and
  .renderedProfiles == ["lapras","ditto","rotom","absol"] and
  .localExecutableRender == {outcome:"Pass",reasonCode:"ContractSatisfied"} and
  .castformExecutable.outcome == "Unavailable" and .eeveeExecutable.outcome == "Unavailable"
' "$profile_rendered" >/dev/null || fail 'the controlled renderer report did not bind the four local profiles'
"$profile_validator" --base-uri "file://$work/schemas/ci/" \
  --schemafile "$work/schemas/ci/diene-profile-report-v1.schema.json" "$profile_rendered" >/dev/null ||
  fail 'the controlled renderer report is not schema-valid'
jq -e '
  (keys_unsorted | sort) == [
    "apiVersion","castformExecutable","eeveeExecutable","localExecutableRender",
    "outcome","previewManifest","reasonCode","renderedProfiles","repositoryRevision",
    "staticContract","toolingDigests","validatedProfiles"
  ] and
  .validatedProfiles == ["eevee","castform"] and
  (.renderedProfiles | all(. != "eevee" and . != "castform")) and
  .castformExecutable == {outcome:"Unavailable",reasonCode:"PreviewIdentityUnavailable"} and
  .eeveeExecutable == {outcome:"Unavailable",reasonCode:"PreviewIdentityUnavailable"} and
  (has("rejectedAliases") | not)
' "$profile_rendered" >/dev/null ||
  fail 'the profile report invented a field or claimed a hosted preview render'
profile_lock_digest="sha256:$(sha256sum "$work/.diene/ci/environment-lock.v1.json" | awk '{print $1}')"
jq -e --arg sha "$SOURCE_SHA" --arg lockDigest "$profile_lock_digest" '
  .repositoryRevision == $sha and
  .toolingDigests == {environmentLockDigest:$lockDigest} and
  .previewManifest == {
    schemaVersion:"preview-manifest/v1",
    schemaDigest:"sha256:3333333333333333333333333333333333333333333333333333333333333333",
    wordListVersion:"v1"
  }
' "$profile_rendered" >/dev/null ||
  fail 'the profile report did not bind the exact revision, lock digest, and imported manifest entry'
[[ $(<"$profile_renderer_log") == $'lapras\nditto\nrotom\nabsol' ]] ||
  fail 'the renderer was called with something other than the exact four local profiles'
grep -Fxq "profile_report=$profile_rendered" "$profile_output" ||
  fail 'the controlled profile report path was not published through GITHUB_OUTPUT'
profile_report_digest="sha256:$(sha256sum "$profile_rendered" | awk '{print $1}')"
grep -Fxq "profile_report_digest=$profile_report_digest" "$profile_output" ||
  fail 'the controlled profile report digest was not published exactly'
[[ $(stat -c '%a' "$profile_rendered") == 600 ]] ||
  fail 'the controlled profile report is not mode 0600'
profile_temp_leftover=$(find "$scratch/profile-temp" -mindepth 1 -print -quit)
[[ -z $profile_temp_leftover ]] ||
  fail "profile contract left a scratch-scoped temporary object: $profile_temp_leftover"
ok 'controlled local renders pass while hosted previews and unratified roster/pin evidence remain Unavailable'

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

journeys_backup=$scratch/journeys.backup
cp "$work/.diene/ci/journeys.v1.yaml" "$journeys_backup"
jq '
  .journeys |= map(if .id == "core-demo" then
    .appliesTo = [{lane:"absol",profile:"absol",buildMode:"build-local"}]
  else . end)
' "$journeys_backup" >"$work/.diene/ci/journeys.v1.yaml"
prepare_run 3022 ditto-build-local
expect_precreate_refusal JourneySelectorUnsatisfied ./scripts/ci/environment-k3d-run.sh orchestrate

jq '
  .journeys |= map(if .id == "core-demo" then
    .appliesTo = [{lane:"ditto-build-local",profile:"ditto",buildMode:"build-local"}]
  else . end)
' "$journeys_backup" >"$work/.diene/ci/journeys.v1.yaml"
prepare_run 3023 ditto-target-pull
expect_precreate_refusal JourneySelectorUnsatisfied ./scripts/ci/environment-k3d-run.sh orchestrate

jq '.journeys |= map(select(.id != "fleet-demo"))' \
  "$journeys_backup" >"$work/.diene/ci/journeys.v1.yaml"
prepare_run 3024 fleet-independence
expect_precreate_refusal JourneySelectorUnsatisfied ./scripts/ci/environment-k3d-run.sh orchestrate
cp "$journeys_backup" "$work/.diene/ci/journeys.v1.yaml"

validate_prerequisites_case() (
  cd -- "$work"
  ./scripts/ci/environment-profile-contract.sh --validate-prerequisites
)
prerequisite_run=3030
for lane in ditto-build-local ditto-target-pull absol fleet-independence; do
  prepare_run "$prerequisite_run" "$lane"
  validate_prerequisites_case >"$scratch/prerequisites-$lane.out" \
    2>"$scratch/prerequisites-$lane.err" || {
    sed -n '1,120p' "$scratch/prerequisites-$lane.err" >&2
    fail "the exact $lane four-tuple did not pass the pre-create selector"
  }
  assert_contains "$scratch/prerequisites-$lane.out" PreSitContractAccepted
  prerequisite_run=$((prerequisite_run + 1))
done
jq -e '
  (.properties.outcome.enum | sort) == ["Fail","NotApplicable","Pass","Unavailable"] and
  (.["$defs"].check.properties.outcome.enum | sort) == ["Fail","NotApplicable","Pass","Unavailable"]
' "$work/schemas/ci/diene-profile-report-v1.schema.json" >/dev/null ||
  fail 'the profile result vocabulary widened beyond Pass|Fail|NotApplicable|Unavailable'
jq -e '
  (.["$defs"].outcome.properties.outcome.enum | sort) == ["Fail","NotApplicable","Pass","Unavailable"]
' "$work/schemas/ci/diene-environment-report-v1.schema.json" >/dev/null ||
  fail 'the journey result vocabulary widened beyond Pass|Fail|NotApplicable|Unavailable'
ok 'exact four-tuples pass while another-lane, target/build-local, and fleet-isolation mismatches refuse before create'
ok 'trust, selectors, closure, vendor, producer, and fixture defects all stop before create'

printf '== exact Namespace CLI identity refuses version drift before create ==\n'

prepare_run 3050
exact_nsc_identity=$(
  cd -- "$work"
  # shellcheck source=/dev/null
  source ./scripts/ci/environment-lib.sh
  diene_nsc_identity
)
jq -e --arg binary "$fake_nsc_binary_digest" '
  .version == "v0.0.532" and
  .artifactDigest == "sha256:6666666666666666666666666666666666666666666666666666666666666666" and
  .binaryDigest == $binary
' <<<"$exact_nsc_identity" >/dev/null || fail 'the exact fake nsc identity did not validate as an object'
ok 'exact v0.0.532 version, release artifact, and executable digest are accepted'

for nsc_drift in older newer; do
  prepare_run "$([[ $nsc_drift == older ]] && printf 3051 || printf 3052)"
  expect_precreate_refusal NamespaceLifecycleUnavailable env \
    FAKE_NSC_SCENARIO="nsc-$nsc_drift" ./scripts/ci/environment-k3d-run.sh orchestrate
done
bad_nsc_identity=$scratch/bad-nsc-identity.json
jq '.binaryDigest = "sha256:9999999999999999999999999999999999999999999999999999999999999999"' \
  "$fake_nsc_identity" >"$bad_nsc_identity"
prepare_run 3053
expect_precreate_refusal NamespaceLifecycleUnavailable env \
  DIENE_NSC_IDENTITY_FILE="$bad_nsc_identity" ./scripts/ci/environment-k3d-run.sh orchestrate
ok 'older, newer, and executable-identity drift all refuse before nsc create'

printf '== hostile source archives refuse before create ==\n'

unicode_listing=$scratch/canonical-unicode.list
LC_ALL=C tar --list --quoting-style=escape --file "$source_archive" >"$unicode_listing"
grep -F -- '\342\232\241reusable-environment-k3d.yaml' "$unicode_listing" >/dev/null ||
  fail 'the source fixture did not exercise the canonical UTF-8 workflow name'
(
  # shellcheck source=/dev/null
  source "$work/scripts/ci/environment-lib.sh"
  diene_require_archive_members "$source_archive" \
    scripts/ci/environment-k3d-run.sh schemas/ci/diene-environment-report-v1.schema.json
) || fail 'a canonical archive containing the UTF-8 workflow name was rejected'
ok 'canonical UTF-8 git-archive names remain accepted'

hostile_run=3060
for hostile_kind in traversal absolute symlink hardlink fifo device; do
  prepare_run "$hostile_run"
  expect_precreate_refusal UntrustedSubject env \
    DIENE_SOURCE_ARCHIVE="$hostile_archive_dir/$hostile_kind.tar" \
    ./scripts/ci/environment-k3d-run.sh orchestrate
  hostile_run=$((hostile_run + 1))
done
ok 'traversal, absolute, symlink, hardlink, FIFO, and device source archives all refuse before create'

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

grep -Eq '^create --ephemeral --duration 2h --enable=kubernetes:1\.33 --wait_kube_system .*--output_json_to .*--output json .*--purpose .*--unique_tag .*--label .*--label .*--label ' \
  "$happy_log" || fail 'fake nsc did not observe the exact stable create surface'
[[ $(grep -o -- '--enable=[^ ]*' "$happy_log" | wc -l) == 1 ]] ||
  fail 'create did not pass exactly one Kubernetes feature selector'
[[ $(grep -o -- '--enable=[^ ]*' "$happy_log") == '--enable=kubernetes:1.33' ]] ||
  fail 'the create feature selector was not the exact derived admitted minor'
jq -e '.kubernetes_feature == "kubernetes:1.33" and .labels["nsc.kubernetes"] == "1.33"' \
  "$FAKE_NSC_ROOT/instances/$happy_cluster/meta.json" >/dev/null ||
  fail 'create metadata did not retain the selected Kubernetes feature'
if grep -Eq -- '(^| )--bare( |$)|--k3s[-_]image|--image( |=)|--ingress|--endpoint' "$happy_log"; then
  fail 'create substituted a bare, replacement-image, ingress, or endpoint surface'
fi
expected_uploads=$scratch/expected-guest-nix-uploads
actual_uploads=$scratch/actual-guest-nix-uploads
printf '%s\n' \
  /run/diene-ci/archive-validator.sh \
  /run/diene-ci/archive-validator.sha256 \
  /run/diene-ci/artifact-subject.json \
  /run/diene-ci/egress-contract.json \
  /run/diene-ci/guest-nix-bootstrap.sh \
  /run/diene-ci/guest-nix-bootstrap.sha256 \
  /run/diene-ci/guest-nix-installer \
  /run/diene-ci/guest-nix-installer.sha256 \
  /run/diene-ci/inputs.json \
  /run/diene-ci/receipt.json \
  /run/diene-ci/source.tar | LC_ALL=C sort >"$expected_uploads"
awk '$1 == "instance" && $2 == "upload" {print $5}' "$happy_log" | LC_ALL=C sort >"$actual_uploads"
diff -u "$expected_uploads" "$actual_uploads" >/dev/null ||
  fail 'the immutable upload path set is not the exact seven originals plus four guest Nix files'
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
jq -e --arg binary "$fake_nsc_binary_digest" '
  .tooling.nscVersion == "v0.0.532" and
  .tooling.nscArtifactDigest ==
    "sha256:6666666666666666666666666666666666666666666666666666666666666666" and
  .tooling.nscBinaryDigest == $binary
' "$happy_core_report" >/dev/null || fail 'the final report lost exact immutable nsc identity evidence'
tar -xOf "$happy_core_bundle" ci-receipt.json >"$scratch/happy-receipt.json"
jq -e --arg binary "$fake_nsc_binary_digest" '
  .tooling.nscVersion == "v0.0.532" and
  .tooling.nscArtifactDigest ==
    "sha256:6666666666666666666666666666666666666666666666666666666666666666" and
  .tooling.nscBinaryDigest == $binary
' "$scratch/happy-receipt.json" >/dev/null || fail 'the exact receipt lost immutable nsc identity evidence'
ok 'create/cid agreement/upload/ssh/download/exact destroy/list absence use measured nsc syntax'

happy_instance_state="$FAKE_NSC_ROOT/instances/$happy_cluster/fs/run/diene-ci"
for guest_asset in guest-nix-bootstrap.sh guest-nix-bootstrap.sha256 \
  guest-nix-installer guest-nix-installer.sha256; do
  [[ -f $happy_instance_state/$guest_asset && ! -L $happy_instance_state/$guest_asset ]] ||
    fail "the verified guest Nix upload $guest_asset is absent"
  [[ $(stat -c %a -- "$happy_instance_state/$guest_asset") == 600 ]] ||
    fail "the verified guest Nix upload $guest_asset is not mode 0600"
done
(cd "$happy_instance_state" && sha256sum -c guest-nix-bootstrap.sha256 >/dev/null &&
  sha256sum -c guest-nix-installer.sha256 >/dev/null) ||
  fail 'the uploaded guest Nix assets do not match their exact sidecars'
grep -Fxq -- 'installer-argv install linux --no-confirm --init none' "$FAKE_GUEST_NIX_EVENT_LOG" ||
  fail 'the fake installer did not capture the exact measured install argv'
grep -Fxq -- nix-develop "$FAKE_GUEST_NIX_EVENT_LOG" ||
  fail 'the happy guest rail did not reach nix develop after its identity gates'
ok 'both private pinned assets and exact sidecars upload and re-verify before the measured installer argv'

happy_collected=$(find "$RUNNER_TEMP/diene-namespace" -path '*/collected/evidence' -type d -print -quit)
[[ -n $happy_collected ]] || fail 'the happy lifecycle retained no safely extracted evidence tree'
happy_identity=$happy_collected/guest-nix/identity.json
happy_preflight=$happy_collected/preflight.json
[[ -f $happy_identity && ! -L $happy_identity && $(stat -c %a -- "$happy_identity") == 600 ]] ||
  fail 'the collected guest Nix identity receipt is not a regular mode-0600 file'
happy_identity_digest="sha256:$(sha256sum "$happy_identity" | awk '{print $1}')"
jq -e --arg digest "$happy_identity_digest" --slurpfile identity "$happy_identity" '
  .guestNix.payloadDigestVerified == true and
  .guestNix.executionMode == "direct-pinned-binary" and
  .guestNix.installerVersion == "nix-installer 3.21.9" and
  .guestNix.nixVersion == "nix (Determinate Nix 3.21.9) 2.34.8" and
  .guestNix.argv == ["install","linux","--no-confirm","--init","none"] and
  .guestNix.identityReceiptDigest == $digest and
  (.guestNix | del(.identityReceiptDigest)) == $identity[0]
' "$happy_preflight" >/dev/null ||
  fail 'the collected identity receipt and preflight object do not agree exactly'
happy_preflight_digest="sha256:$(sha256sum "$happy_preflight" | awk '{print $1}')"
jq -e --arg digest "$happy_preflight_digest" '
  [.checkpoints[] | select(.id == "instance-preflight" and .evidenceDigest == $digest)] | length == 1
' "$happy_collected/checkpoint-chain.json" >/dev/null ||
  fail 'the checkpoint chain does not bind the preflight object containing the identity receipt digest'
ok 'mode-0600 guest Nix identity agrees with preflight and is transitively checkpoint-bound'

happy_socket=$happy_collected/staging/orchestration/ss-observation.txt
[[ -f $happy_socket && ! -L $happy_socket && $(stat -c %a -- "$happy_socket") == 600 ]] ||
  fail 'the safely collected proof lost the regular mode-0600 raw socket observation'
happy_socket_digest="sha256:$(sha256sum "$happy_socket" | awk '{print $1}')"
jq -e --arg digest "$happy_socket_digest" '
  .orchestrationTupleSource == "kernel-ss" and
  .orchestrationObservationArtifact == "orchestration/ss-observation.txt" and
  .orchestrationObservationDigest == $digest
' "$happy_collected/policy.json" >/dev/null ||
  fail 'collected policy.json does not digest-bind the retained raw socket observation'
ok 'the safely extracted proof retains the raw socket artifact bound by collected policy.json'

uploaded_validator="$FAKE_NSC_ROOT/instances/$happy_cluster/fs/run/diene-ci/archive-validator.sh"
[[ -x $uploaded_validator ]] || fail 'the immutable remote archive validator was not uploaded'
for hostile_kind in traversal absolute symlink hardlink fifo device; do
  remote_extract=$scratch/remote-hostile-$hostile_kind
  if "$uploaded_validator" "$hostile_archive_dir/$hostile_kind.tar" "$remote_extract" \
    >"$remote_extract.out" 2>"$remote_extract.err"; then
    fail "the uploaded validator accepted a $hostile_kind source archive"
  fi
  assert_contains "$remote_extract.err" UntrustedSubject
  [[ ! -e $remote_extract && ! -L $remote_extract ]] ||
    fail "the uploaded validator extracted the $hostile_kind source archive before refusal"
done
ok 'the locally executed remote validator rejects every unsafe name and member type before extraction'

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

verify_lifecycle_main_case() (
  cd -- "$work"
  # shellcheck source=/dev/null
  source ./scripts/ci/environment-k3d-run.sh
  environment_k3d_main lifecycle "$happy_core_bundle"
  [[ -z $(trap -p RETURN) ]] || fail 'lifecycle main leaked a RETURN trap past local cleanup scope'
)
nsc_lines_before=$(wc -l <"$happy_log")
verify_lifecycle_main_case >"$scratch/lifecycle-main.out" 2>"$scratch/lifecycle-main.err" || {
  sed -n '1,160p' "$scratch/lifecycle-main.err" >&2
  fail 'the source-safe lifecycle main rejected the green proof or leaked its RETURN trap'
}
[[ $(wc -l <"$happy_log") == "$nsc_lines_before" ]] ||
  fail 'the source-safe lifecycle main invoked Namespace authority'
assert_contains "$scratch/lifecycle-main.out" 'NamespaceLifecycleVerified:'
ok 'source-safe lifecycle main clears its local RETURN trap after a successful proof'

lifecycle_extract=$scratch/lifecycle-extract
install -d -m 0700 "$lifecycle_extract"
tar -xf "$happy_core_bundle" -C "$lifecycle_extract"
jq -e --slurpfile lifecycle "$lifecycle_extract/namespace-lifecycle.json" '
  .namespace.clusterId == $lifecycle[0].clusterId and
  .namespace.create.outcome == "Pass" and .namespace.destroy.outcome == "Pass" and
  .namespace.absence.outcome == "Pass" and
  .namespace.create.receiptDigest == $lifecycle[0].create.receiptDigest and
  .namespace.destroy.receiptDigest == $lifecycle[0].destroy.receiptDigest and
  .namespace.absence.receiptDigest == $lifecycle[0].absence.receiptDigest and
  .namespace.policy.applied == true and .namespace.policy.hostileProbes == "Pass" and
  .cleanup.outcome == "Pass" and (.cleanup.debt // []) == []
' "$lifecycle_extract/ci-receipt.json" >/dev/null ||
  fail 'the terminal receipt is not bound to every passing lifecycle phase and digest'
ok 'mandatory receipt binds the exact cluster, create/destroy/absence Pass phases, digests, policy, and cleanup'

repack_lifecycle_bundle() {
  local source_bundle=${1:?source bundle required} target_bundle=${2:?target bundle required}
  local label=${3:?label required} mutation=${4-}
  local repack_dir=$scratch/repack-$label
  install -d -m 0700 "$repack_dir"
  tar -xf "$source_bundle" -C "$repack_dir"
  case $label in
    omitted-receipt) rm -f -- "$repack_dir/ci-receipt.json" ;;
    unexpected-member) printf '%s\n' hostile >"$repack_dir/notes.txt" ;;
    *)
      jq "$mutation" "$repack_dir/ci-receipt.json" >"$repack_dir/ci-receipt.json.tmp"
      mv "$repack_dir/ci-receipt.json.tmp" "$repack_dir/ci-receipt.json"
      ;;
  esac
  local -a members=(diene-environment-report.v1.json namespace-lifecycle.json checkpoint-chain.json)
  [[ $label == omitted-receipt ]] || members+=(ci-receipt.json)
  [[ $label != unexpected-member ]] || members+=(notes.txt)
  tar -cf "$target_bundle" -C "$repack_dir" "${members[@]}"
}

verify_lifecycle_bundle_case() (
  local selected_bundle=${1:?bundle required}
  cd -- "$work"
  FAKE_NSC_SCENARIO=happy ./scripts/ci/environment-k3d-run.sh lifecycle "$selected_bundle"
)

expect_terminal_bundle_refusal() {
  local reason=${1:?reason required} label=${2:?label required} mutation=${3-}
  local bundle=$scratch/lifecycle-$label.tar before
  repack_lifecycle_bundle "$happy_core_bundle" "$bundle" "$label" "$mutation"
  before=$(wc -l <"$happy_log")
  expect_refusal "$reason" verify_lifecycle_bundle_case "$bundle"
  [[ $(wc -l <"$happy_log") == "$before" ]] ||
    fail "$label terminal verifier invoked Namespace authority"
}

expect_terminal_bundle_refusal EvidenceCollectionFailed omitted-receipt
expect_terminal_bundle_refusal ReceiptLifecycleIncomplete foreign-cluster \
  '.namespace.clusterId = "cluster-foreign-terminal"'
expect_terminal_bundle_refusal ReceiptLifecycleIncomplete foreign-allocation \
  '.owner.allocationKey = "r99999-w99999-a9-lditto-build-local"'
expect_terminal_bundle_refusal ReceiptLifecycleIncomplete foreign-generation \
  '.owner.generationKey = "gffffffffffff"'
expect_terminal_bundle_refusal ReceiptLifecycleIncomplete create-phase \
  '.namespace.create.outcome = "Fail" | .namespace.create.reasonCode = "Tampered"'
expect_terminal_bundle_refusal ReceiptLifecycleIncomplete destroy-digest \
  '.namespace.destroy.receiptDigest = "sha256:9999999999999999999999999999999999999999999999999999999999999999"'
expect_terminal_bundle_refusal ReceiptLifecycleIncomplete absence-phase \
  '.namespace.absence = {outcome:"Pending",reasonCode:"AbsenceNotAttempted"}'
expect_terminal_bundle_refusal ReceiptLifecycleIncomplete cleanup-debt \
  '.cleanup = {outcome:"Fail",reasonCode:"ExactDownFailed",debt:["tampered debt"]}'
expect_terminal_bundle_refusal ReceiptLifecycleIncomplete receipt-unpatched \
  '.namespace.policy.applied = false | .namespace.policy.hostileProbes = "Pending" |
   .cleanup = {outcome:"Pending",reasonCode:"RuntimeArmed",debt:[]}'
expect_terminal_bundle_refusal EvidenceCollectionFailed unexpected-member

terminal_receipt_link=$scratch/terminal-receipt-link.json
ln -s "$lifecycle_extract/ci-receipt.json" "$terminal_receipt_link"
validate_terminal_receipt_case() (
  cd -- "$work"
  # shellcheck source=/dev/null
  source ./scripts/ci/environment-lib.sh
  diene_validate_terminal_receipt "$terminal_receipt_link" \
    "$lifecycle_extract/namespace-lifecycle.json" \
    "$lifecycle_extract/checkpoint-chain.json" \
    "$lifecycle_extract/diene-environment-report.v1.json"
)
expect_refusal ReceiptLifecycleIncomplete validate_terminal_receipt_case
ok 'omission, owner/allocation/generation/cluster, phase, digest, cleanup, Pending, symlink, and extra-member terminal receipts all refuse'

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
  case $scenario in
    remote-source-special) export FAKE_HOSTILE_SOURCE_ARCHIVE="$hostile_archive_dir/fifo.tar" ;;
    proof-fifo | proof-unreadable) printf '%s\n' stale-proof-sentinel >"$DIENE_PROOF_BUNDLE" ;;
  esac
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
  FAILURE_RUNNER=$RUNNER_TEMP
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

expect_lifecycle_failure 5007 proof-fifo EvidenceCollectionFailed
[[ ! -e $DIENE_CORE_REPORT && ! -e $DIENE_PROOF_BUNDLE ]] ||
  fail 'a special collected proof left a report or stale proof artifact publishable'
assert_contains "$scratch/failure-proof-fifo.err" EvidenceLeakageInterfaceUnavailable
proof_fifo_id=$(find "$FAILURE_NSC_ROOT/instances" -name meta.json -exec jq -r '.cluster_id' {} \;)
[[ $(grep -Ec "^destroy --force ${proof_fifo_id} " "$FAILURE_LOG") == 1 ]] ||
  fail 'special collected proof did not preserve exact cleanup'

expect_lifecycle_failure 5008 proof-unreadable EvidenceCollectionFailed
[[ ! -e $DIENE_CORE_REPORT && ! -e $DIENE_PROOF_BUNDLE ]] ||
  fail 'an unreadable collected tree left a report or stale proof artifact publishable'
assert_contains "$scratch/failure-proof-unreadable.err" EvidenceLeakageInterfaceUnavailable
ok 'special and unreadable proof members suppress all artifacts after exact cleanup'

expect_lifecycle_failure 5009 remote-source-special NamespaceSshDriverFailed
remote_stderr=$(find "$FAILURE_RUNNER/diene-namespace" -path '*/staging/stderr' -print -quit)
[[ -n $remote_stderr ]] && assert_contains "$remote_stderr" UntrustedSubject
remote_special_id=$(find "$FAILURE_NSC_ROOT/instances" -name meta.json -exec jq -r '.cluster_id' {} \;)
[[ $(grep -Ec "^destroy --force ${remote_special_id} " "$FAILURE_LOG") == 1 ]] ||
  fail 'remote archive revalidation failure did not preserve exact cleanup'
ok 'the uploaded fixed validator repeats source safety before remote extraction'

prepare_run 5010
printf '%s\n' stale-proof-sentinel >"$DIENE_PROOF_BUNDLE"
export DIENE_GREP_BIN=$fake_grep_error
if run_orchestrator happy >"$scratch/failure-grep-error.out" 2>"$scratch/failure-grep-error.err"; then
  fail 'a leakage scanner status 2 unexpectedly published a green lifecycle'
fi
assert_contains "$scratch/failure-grep-error.err" EvidenceLeakageInterfaceUnavailable
[[ ! -e $DIENE_CORE_REPORT && ! -e $DIENE_PROOF_BUNDLE ]] ||
  fail 'grep status 2 left a final report or pre-existing proof sentinel'
grep_error_id=$(find "$FAKE_NSC_ROOT/instances" -name meta.json -exec jq -r '.cluster_id' {} \;)
[[ $(grep -Ec "^destroy --force ${grep_error_id} " "$FAKE_NSC_LOG") == 1 ]] ||
  fail 'leakage scanner failure did not preserve exact cleanup'
ok 'grep status 2 preserves interface-unavailable and removes every stale publication artifact'

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
    jq -n --argjson podCidrs "${FAKE_NODE_POD_CIDRS:-[\"10.142.0.0/16\",\"fd00:142::/64\"]}" '
      {items:[{spec:{podCIDR:($podCidrs | map(select(contains(":" ) | not))[0]),podCIDRs:$podCidrs},
      status:{conditions:[{type:"Ready",status:"True"}],capacity:{cpu:"16",memory:"32Gi"}}}]}'
    ;;
  'get servicecidrs.networking.k8s.io kubernetes -o json')
    [[ ${FAKE_SERVICE_CIDR_MODE:-happy} != unavailable ]] || exit 1
    jq -n --arg api "${FAKE_SERVICE_CIDR_API:-networking.k8s.io/v1}" \
      --arg kind "${FAKE_SERVICE_CIDR_KIND:-ServiceCIDR}" \
      --arg name "${FAKE_SERVICE_CIDR_NAME:-kubernetes}" \
      --argjson cidrs "${FAKE_SERVICE_CIDRS:-[\"10.143.0.0/16\"]}" '
      {apiVersion:$api,kind:$kind,metadata:{name:$name},spec:{cidrs:$cidrs}}'
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
ipv6_enabled_path=$scratch/ipv6-enabled
ipv6_disabled_path=$scratch/ipv6-disabled
: >"$policy_table_log"
: >"$policy_kubectl_log"
: >"$policy_l7_log"
: >"$policy_probe_log"
printf '0\n' >"$ipv6_enabled_path"
printf '1\n' >"$ipv6_disabled_path"

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
  export DIENE_IPV6_DISABLE_PATH="$ipv6_enabled_path"
  export FAKE_TABLE_STATE="$policy_state" FAKE_TABLE_LOG="$policy_table_log"
  export FAKE_KUBECTL_LOG="$policy_kubectl_log" FAKE_L7_LOG="$policy_l7_log"
  export FAKE_PROBE_LOG="$policy_probe_log" SSH_CONNECTION='192.0.2.10 4242 10.0.0.2 22'
  export PATH="$policy_tools:$PATH"
  export DIENE_EVIDENCE_STAGING="$policy_evidence/staging"
  install -d -m 0700 "$DIENE_EVIDENCE_STAGING"
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
  .orchestrationException == "exact-ssh-4-tuple" and
  .orchestrationTupleSource == "ssh-environment" and .applied == true' \
  "$policy_evidence/policy.json" >/dev/null || fail 'policy transcript lacks host/FORWARD/IPv6/exact-SSH facts'
# The primary source binds the same canonical tuple, a measured selected count,
# and a deterministic digest of the exact admitted one-line value, with no
# retained artifact because no kernel socket table was read.
jq -e --arg digest "sha256:$(printf '%s' '192.0.2.10 4242 10.0.0.2 22' | sha256sum | awk '{print $1}')" '
  .orchestrationTuple == {clientAddress:"192.0.2.10",clientPort:4242,
    serverAddress:"10.0.0.2",serverPort:22} and
  .orchestrationFlowCount == 1 and
  .orchestrationObservationDigest == $digest and
  .orchestrationObservationArtifact == null' \
  "$policy_evidence/policy.json" >/dev/null ||
  fail 'the ssh-environment transcript did not bind the exact tuple, count, and observation digest'
jq -e '.outcome == "Pass" and .defaultDenied == true and .dnsBound == true and
  .sniBound == true and .methodsBound == true' "$policy_evidence/l7.json" >/dev/null ||
  fail 'L7 enforcer did not attest the full declaration boundary'
jq -e 'length == 6 and
  ([.[].id] | sort) == ["host-arbitrary-https-denial","host-metadata-denial",
    "pod-arbitrary-https-denial","pod-dns-denial","pod-metadata-denial",
    "preexisting-flow-transition-denial"] and
  all(.outcome == "Pass" and .required == true and .reasonCode == "AdapterObservedDenial")' \
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
[[ $(grep -Fc -- '--image ' "$policy_probe_log") == 1 ]] ||
  fail 'an adapter scope other than pod received the canary image argument'
policy_receipt_id=$(
  cd -- "$work"
  # shellcheck source=/dev/null
  source ./scripts/ci/environment-lib.sh
  diene_receipt_id
)
for scope in preexisting-open preexisting-transition host pod; do
  transcript=$policy_evidence/staging/egress-probe/$scope.json
  expected_probe_reason=AdapterObservedDenial
  [[ $scope != preexisting-open ]] || expected_probe_reason=AdapterObservedFlowEstablished
  jq -e --arg scope "$scope" --arg profile ditto-build-local-v1 \
    --arg cluster cluster-policy-7001 --arg receipt "$policy_receipt_id" \
    --arg reason "$expected_probe_reason" '
    (keys | sort) == ["apiVersion","clusterId","observations","profileId","receiptId","scope"] and
    .apiVersion == "diene.atomi.cloud/ci-egress-probe/v1" and .scope == $scope and
    .profileId == $profile and .clusterId == $cluster and .receiptId == $receipt and
    all(.observations[];
      (keys | sort) == ["id","outcome","reasonCode","required"] and
      .outcome == "Pass" and .required == true and .reasonCode == $reason)
  ' "$transcript" >/dev/null || fail "$scope adapter transcript lost exact tuple/key/outcome binding"
done
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
ok 'iptables-nft and exact machine-readable adapter transcripts bind host/pod probes, receipt, and full removal'

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
  local pod_cidrs=${6:-'["10.142.0.0/16","fd00:142::/64"]'} ipv6_disabled=${7:-0}
  prepare_run "$run_id"
  local state=$scratch/policy-failure-$label tables=$scratch/policy-failure-$label.log
  local l7_log=$scratch/policy-failure-$label-l7.log evidence=$scratch/policy-failure-$label-evidence
  install -d -m 0700 "$state" "$evidence"
  : >"$tables"
  : >"$l7_log"
  printf '%s\n' "$ipv6_disabled" >"$evidence/ipv6-disabled"
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
    export DIENE_IPV6_DISABLE_PATH="$evidence/ipv6-disabled" FAKE_NODE_POD_CIDRS="$pod_cidrs"
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

policy_failure_case 7104 ipv6-no-pod-cidr '' true InterimPolicyUnavailable \
  '["10.142.0.0/16"]' 0
assert_contains "$scratch/policy-failure-ipv6-no-pod-cidr.err" \
  'host IPv6 is enabled but no IPv6 pod CIDR was observed'
! grep -Eq -- '-A DI6F_[0-9a-f]+ -j RETURN' "$POLICY_FAILURE_TABLE_LOG" ||
  fail 'the empty-pod6-CIDR case completed an unenforced IPv6 forwarding chain'
ok 'partial IPv4/IPv6, L7, and enabled-host/empty-pod6 failures leave no hook or chain'

prepare_run 7105
ipv6_disabled_state=$scratch/policy-ipv6-disabled-state
ipv6_disabled_evidence=$scratch/policy-ipv6-disabled-evidence
ipv6_disabled_log=$scratch/policy-ipv6-disabled.log
install -d -m 0700 "$ipv6_disabled_state" "$ipv6_disabled_evidence"
: >"$ipv6_disabled_log"
jq -n '{network:{serviceCidrs:["10.143.0.0/16"]}}' >"$ipv6_disabled_evidence/preflight.json"
(
  cd -- "$work"
  # shellcheck source=/dev/null
  source ./scripts/ci/environment-lib.sh
  diene_validate_inputs
  export DIENE_NSC_CLUSTER_ID=cluster-ipv6-disabled-7105
  export DIENE_PREFLIGHT_EVIDENCE="$ipv6_disabled_evidence/preflight.json"
  export DIENE_KUBECTL_BIN="$policy_tools/kubectl" DIENE_IPTABLES_BIN="$policy_tools/iptables4"
  export DIENE_IP6TABLES_BIN="$policy_tools/iptables6" DIENE_EGRESS_RESOLVER_BIN="$policy_tools/resolver"
  export DIENE_IPV6_DISABLE_PATH="$ipv6_disabled_path" FAKE_NODE_POD_CIDRS='["10.142.0.0/16"]'
  export FAKE_TABLE_STATE="$ipv6_disabled_state" FAKE_TABLE_LOG="$ipv6_disabled_log"
  export FAKE_KUBECTL_LOG="$policy_kubectl_log" FAKE_L7_LOG="$policy_l7_log"
  export SSH_CONNECTION='192.0.2.10 4242 10.0.0.2 22'
  diene_prepare_egress_contract "$ipv6_disabled_evidence/contract.json"
  diene_resolve_egress_contract "$ipv6_disabled_evidence/contract.json" \
    "$ipv6_disabled_evidence/resolved.json"
  diene_apply_interim_policy "$ipv6_disabled_evidence/resolved.json" \
    "$ipv6_disabled_evidence/policy.json" "$ipv6_disabled_evidence/l7.json"
  diene_remove_interim_policy
) >"$scratch/policy-ipv6-disabled.out" 2>"$scratch/policy-ipv6-disabled.err" || {
  sed -n '1,160p' "$scratch/policy-ipv6-disabled.err" >&2
  fail 'the explicitly IPv6-disabled control refused an empty pod6 CIDR set'
}
jq -e '.ipv6Armed == false and .pod6Cidrs == [] and .applied == true' \
  "$ipv6_disabled_evidence/policy.json" >/dev/null ||
  fail 'the IPv6-disabled control transcript misreported IPv6 enforcement'
assert_policy_state_absent "$ipv6_disabled_state" ipv6-disabled-control
ok 'an explicitly IPv6-disabled host permits no pod6 CIDR and still proves complete removal'

printf '== admitted built-in Kubernetes admission and the derived create selector ==\n'

k3s_admission_case() (
  cd -- "$work"
  # shellcheck source=/dev/null
  source ./scripts/ci/environment-lib.sh
  if (($# >= 1)); then
    diene_k3s_admission "$1"
  else
    diene_k3s_admission
  fi
)

k3s_admission_empty_environment_case() (
  cd -- "$work"
  # shellcheck source=/dev/null
  source ./scripts/ci/environment-lib.sh
  export DIENE_ADMITTED_K3S_VERSION=''
  diene_k3s_admission
)

k3s_admission_default_case() (
  cd -- "$work"
  # shellcheck source=/dev/null
  source ./scripts/ci/environment-lib.sh
  unset DIENE_ADMITTED_K3S_VERSION
  diene_k3s_admission
)

[[ $(k3s_admission_case v1.33.1+k3s1) == 'v1.33.1+k3s1 kubernetes:1.33' ]] ||
  fail 'the exact admitted version did not derive exactly one supported feature'
[[ $(k3s_admission_default_case) == 'v1.33.1+k3s1 kubernetes:1.33' ]] ||
  fail 'the omitted admission default is not the admitted v1.33.1+k3s1 substrate'
for malformed_admission in '' v1.32.3+k3s1 v1.34.0+k3s1 1.33.1+k3s1 v1.33.1 v1.33+k3s1 \
  'v1.33.1+k3s1 extra' v1.33.1+k3s v1.33.1-k3s1 v1.33.01+k3s1 v1.33.1+k3s01 v01.33.1+k3s1 \
  v1.033.1+k3s1 V1.33.1+k3s1 v1.33.1+K3S1; do
  expect_refusal InputContractInvalid k3s_admission_case "$malformed_admission"
done
expect_refusal InputContractInvalid k3s_admission_empty_environment_case
ok 'one helper is the source of truth for the admitted version and its single derived feature'

k3s_runtime_case() (
  cd -- "$work"
  # shellcheck source=/dev/null
  source ./scripts/ci/environment-lib.sh
  diene_require_admitted_k3s_runtime "${1-}" "${2-}" "${3-}"
)

k3s_runtime_case v1.33.1+k3s1 v1.33.1+k3s1 v1.33.1+k3s1 ||
  fail 'the exact admitted runtime pair was refused'
expect_refusal InstancePostureUnavailable k3s_runtime_case v1.33.1+k3s1 v1.32.3+k3s1 v1.32.3+k3s1
expect_refusal InstancePostureUnavailable k3s_runtime_case v1.33.1+k3s1 v1.33.2+k3s1 v1.33.2+k3s1
expect_refusal InstancePostureUnavailable k3s_runtime_case v1.33.1+k3s1 v1.33.1+k3s1 v1.32.3+k3s1
expect_refusal InstancePostureUnavailable k3s_runtime_case v1.33.1+k3s1 v1.32.3+k3s1 v1.33.1+k3s1
expect_refusal InstancePostureUnavailable k3s_runtime_case v1.33.1+k3s1 '' v1.33.1+k3s1
expect_refusal InstancePostureUnavailable k3s_runtime_case v1.33.1+k3s1 v1.33.1+k3s1 ''
expect_refusal InstancePostureUnavailable k3s_runtime_case '' v1.33.1+k3s1 v1.33.1+k3s1
expect_refusal InputContractInvalid k3s_runtime_case not-a-version v1.33.1+k3s1 v1.33.1+k3s1
ok 'both observed runtime versions must equal the same admitted version'

# Binding regression: the helpers above are only worth their coverage if the real
# in-guest preflight is the caller. Prove the production seam, and prove the
# disproved k3s argv/config service-range scan is gone rather than demoted.
runner_preflight=$template_root/scripts/ci/environment-runner-preflight.sh
# The seams are matched as production source text, so they must stay unexpanded.
# shellcheck disable=SC2016
for required_seam in 'diene_require_admitted_k3s_runtime "${DIENE_ADMITTED_K3S_VERSION:-}"' \
  'diene_observe_admitted_service_cidr "${DIENE_K3S_SERVICE_CIDR:-}"'; do
  rg -qF -- "$required_seam" "$runner_preflight" ||
    fail "the real runner preflight no longer calls $required_seam"
done
if rg -n -- '--service-cidr|/etc/rancher/k3s/config\.yaml|ps -eo' "$runner_preflight" \
  >"$scratch/preflight-cidr-guess"; then
  sed -n '1,40p' "$scratch/preflight-cidr-guess" >&2
  fail 'the real runner preflight still guesses the service range from k3s argv or config'
fi
rg -qF -- "diene_die InstancePostureUnavailable 'the built-in k3s version is unavailable'" \
  "$runner_preflight" ||
  fail 'the real runner preflight does not map a failed k3s version observation to a stable reason'
ok 'the real runner preflight binds both admission helpers and guesses no service range'

fake_create_seq=0
fake_create_argv() {
  fake_create_seq=$((fake_create_seq + 1))
  local root=$scratch/fake-create-$fake_create_seq
  install -d -m 0700 "$root"
  FAKE_NSC_ROOT=$root FAKE_NSC_LOG=$root/log FAKE_NSC_SCENARIO=happy \
    "$fake_nsc" create --ephemeral --duration 2h "$@" --wait_kube_system \
    --cidfile "$root/cluster.cid" --output_json_to "$root/create.json" --output json \
    --purpose 'diene-ci-k3d/v1 ditto-build-local' --unique_tag "contract-tag-$fake_create_seq" \
    --label diene_receipt=r --label diene_run=1 --label diene_attempt=1 \
    >"$root/out.json" 2>"$root/err"
}

fake_create_argv --enable=kubernetes:1.33 ||
  fail 'the fake create parser refused the exact derived feature selector'
jq -e '.kubernetes_feature == "kubernetes:1.33"' \
  "$scratch/fake-create-$fake_create_seq/instances/"*/meta.json >/dev/null ||
  fail 'the fake create parser did not retain the selected feature semantically'
if fake_create_argv; then
  fail 'the fake create parser accepted a missing feature selector'
fi
for hostile_selector in kubernetes:1.32 kubernetes:1.34 kubernetes: kubernetes:1 1.33 \
  KUBERNETES:1.33 kubernetes:1.33.1 'kubernetes:1.33 ' kubernetes:v1.33; do
  if fake_create_argv "--enable=$hostile_selector"; then
    fail "the fake create parser accepted the refused selector $hostile_selector"
  fi
done
if fake_create_argv --enable=kubernetes:1.33 --enable=kubernetes:1.33; then
  fail 'the fake create parser accepted a duplicate feature selector'
fi
if fake_create_argv --enable=kubernetes:1.33 --enable=kubernetes:1.32; then
  fail 'the fake create parser accepted a second conflicting feature selector'
fi
if fake_create_argv --enable kubernetes:1.33; then
  fail 'the fake create parser accepted a split feature selector'
fi
ok 'the fake create surface requires exactly one exact derived Kubernetes feature selector'

printf '== the admitted service range comes from the one ServiceCIDR object ==\n'

service_cidr_case() (
  cd -- "$work"
  # shellcheck source=/dev/null
  source ./scripts/ci/environment-lib.sh
  export DIENE_KUBECTL_BIN="$policy_tools/kubectl"
  export FAKE_KUBECTL_LOG="$scratch/service-cidr-kubectl.log"
  diene_observe_admitted_service_cidr "${1-}"
)

: >"$scratch/service-cidr-kubectl.log"
[[ $(service_cidr_case 10.143.0.0/16) == 10.143.0.0/16 ]] ||
  fail 'the exact admitted service range was not read from the ServiceCIDR object'
grep -Fq -- 'get servicecidrs.networking.k8s.io kubernetes -o json' \
  "$scratch/service-cidr-kubectl.log" ||
  fail 'the service range was not read from the named networking.k8s.io ServiceCIDR object'
expect_refusal InstancePostureUnavailable service_cidr_case ''
expect_refusal InputContractInvalid service_cidr_case 10.143.0.0/33
expect_refusal InputContractInvalid service_cidr_case 10.143.0.300/16
expect_refusal InputContractInvalid service_cidr_case 10.143.0.0
export FAKE_SERVICE_CIDR_MODE=unavailable
expect_refusal ServiceCidrObservationUnavailable service_cidr_case 10.143.0.0/16
unset FAKE_SERVICE_CIDR_MODE
export FAKE_SERVICE_CIDR_API=networking.k8s.io/v1beta1
expect_refusal ServiceCidrObservationUnavailable service_cidr_case 10.143.0.0/16
unset FAKE_SERVICE_CIDR_API
export FAKE_SERVICE_CIDR_KIND=ServiceCIDRList
expect_refusal ServiceCidrObservationUnavailable service_cidr_case 10.143.0.0/16
unset FAKE_SERVICE_CIDR_KIND
export FAKE_SERVICE_CIDR_NAME=renamed
expect_refusal ServiceCidrObservationUnavailable service_cidr_case 10.143.0.0/16
unset FAKE_SERVICE_CIDR_NAME
for hostile_cidrs in '[]' '["10.143.0.0/16","10.144.0.0/16"]' '["10.143.0.0/16","fd00:143::/108"]' \
  '["fd00:143::/108"]' '["10.143.0.0/33"]' '["not-a-cidr"]' '[null]'; do
  export FAKE_SERVICE_CIDRS=$hostile_cidrs
  expect_refusal ServiceCidrObservationUnavailable service_cidr_case 10.143.0.0/16
done
export FAKE_SERVICE_CIDRS='["10.144.0.0/16"]'
expect_refusal InstancePostureUnavailable service_cidr_case 10.143.0.0/16
unset FAKE_SERVICE_CIDRS
ok 'the ServiceCIDR observation fails closed rather than inferring a range'

printf '== orchestration tuple sources and their fail-closed matrix ==\n'

: >"$scratch/env-source-reader-calls"
tuple_environment_case() (
  cd -- "$work"
  # shellcheck source=/dev/null
  source ./scripts/ci/environment-lib.sh
  # The primary source must execute the kernel socket reader zero times. This
  # stub records every invocation so that claim is proved by behaviour; it is a
  # test-side override only and production keeps no such seam. Its log path comes
  # from the environment because production declares its own `scratch` local that
  # would otherwise shadow the harness global under `set -u`.
  export FAKE_ENV_READER_LOG="$scratch/env-source-reader-calls"
  # shellcheck disable=SC2329
  diene_orchestration_ss_observation() {
    printf 'called\n' >>"${FAKE_ENV_READER_LOG:?}"
    printf '%s\n' 'ESTAB 0 0 10.0.0.2:22 198.51.100.99:5555'
  }
  export SSH_CONNECTION="${1-}"
  diene_observe_orchestration_ssh_tuple
)

tuple_ss_case() (
  cd -- "$work"
  # shellcheck source=/dev/null
  source ./scripts/ci/environment-lib.sh
  printf '%s\n' "${1-}" | diene_parse_orchestration_ss_observation
)

# The primary source now emits one compact JSON object binding the canonical
# tuple, the measured selected count, and a deterministic digest of the exact
# admitted one-line value. No artifact is retained because nothing was read.
env_tuple_observation=$(tuple_environment_case '192.0.2.10 4242 10.0.0.2 22')
jq -e --arg digest "sha256:$(printf '%s' '192.0.2.10 4242 10.0.0.2 22' | sha256sum | awk '{print $1}')" '
  .source == "ssh-environment" and
  .tuple == {clientAddress:"192.0.2.10",clientPort:4242,
    serverAddress:"10.0.0.2",serverPort:22} and
  .flowCount == 1 and .observationDigest == $digest and
  .selectedRow == "192.0.2.10 4242 10.0.0.2 22" and
  .observationArtifact == null' <<<"$env_tuple_observation" >/dev/null ||
  fail 'the valid SSH environment tuple was not bound exactly'
for malformed_tuple in '' ' ' '192.0.2.10 4242 10.0.0.2' '192.0.2.10 4242 10.0.0.2 22 extra' \
  '2001:db8::1 4242 10.0.0.2 22' '192.0.2.10 4242 fd00::2 22' '192.0.2.10 4242 10.0.0.2 2222' \
  '192.0.2.10 99999 10.0.0.2 22' '192.0.2.300 4242 10.0.0.2 22' '192.0.2.10 ssh 10.0.0.2 22' \
  '192.0.2.10 0 10.0.0.2 22' '192.0.2.10 4242 10.0.0.2 022' \
  '0.0.0.0 4242 10.0.0.2 22' '192.0.2.10 4242 0.0.0.0 22' \
  $'192.0.2.10 4242 10.0.0.2 22\ninjected 1 2 3' $'192.0.2.10 4242 10.0.0.2 22\n' \
  $'192.0.2.10 4242 10.0.0.2 22\r' $'192.0.2.10\t4242\t10.0.0.2\t22' \
  '192.0.2.10  4242 10.0.0.2 22'; do
  expect_refusal InterimPolicyUnavailable tuple_environment_case "$malformed_tuple"
done
# Neither the admitted value nor any refusal above may consult the socket table.
[[ ! -s $scratch/env-source-reader-calls ]] ||
  fail 'the SSH environment source executed the kernel socket reader'
ok 'a present SSH environment value is validated exactly and never falls back'

# The fallback reader must stay bound to the fixed absolute iproute2 path, carry
# no state filter, and expose no variable or environment seam a hostile guest
# could redirect. The assertion is scoped structurally to that one function body:
# diene_preflow_start legitimately probes a single destination with
# `ss -Htn state established dst <host:port>`, and that unrelated pre-existing
# flow command must never be conflated with this reader.
assert_fixed_ss_reader() {
  local lib=${1:?library path required} body expected_body
  body=$(awk '/^diene_orchestration_ss_observation/,/^}$/' "$lib")
  [[ -n $body ]] || return 71
  # The state filter is checked first so a filtered reader reports that exact
  # regression: iproute2 omits the State column whenever a filter is supplied,
  # which would leave the established claim resting on the argument instead of on
  # an observed value.
  ! grep -Eq -- '(^|[^[:alnum:]_])state([[:space:]]|$)' <<<"$body" || return 74
  ! grep -Eq -- 'DIENE_SS|ss_bin' <<<"$body" || return 75
  grep -Fxq -- '  diene_require_command /sbin/ss' <<<"$body" || return 72
  grep -Fxq -- '  /sbin/ss -H -n -t -4' <<<"$body" || return 76
  # Whole-body equality, so no appended argv, extra command, redirection, or
  # substitution can hide beside the two exact lines above.
  expected_body=$(printf '%s\n' 'diene_orchestration_ss_observation() {' \
    '  diene_require_command /sbin/ss' \
    '  /sbin/ss -H -n -t -4' \
    '}')
  [[ $body == "$expected_body" ]] || return 73
  return 0
}

production_lib=$template_root/scripts/ci/environment-lib.sh
ss_reader_rc=0
assert_fixed_ss_reader "$production_lib" || ss_reader_rc=$?
[[ $ss_reader_rc == 0 ]] ||
  fail "the production kernel socket reader is not the fixed unfiltered absolute invocation (code $ss_reader_rc)"
rg -qF -- 'ss -Htn state established dst' "$production_lib" ||
  fail 'the unrelated pre-existing flow probe was altered instead of leaving it untouched'

# Negative regression: the tripwire must actually fire on each way the reader
# could regress. A mutant identical to production would make these vacuous.
ss_reader_probe=$scratch/ss-reader-probe
install -d -m 0700 "$ss_reader_probe"
ss_reader_mutant_case() {
  local label=${1:?label required} expected=${2:?expected code required} script=${3:?sed script required}
  local mutant=$ss_reader_probe/$label.sh rc=0
  sed "$script" "$production_lib" >"$mutant"
  ! cmp -s "$production_lib" "$mutant" ||
    fail "the $label reader mutant is byte-identical to production, so its tripwire is vacuous"
  assert_fixed_ss_reader "$mutant" || rc=$?
  [[ $rc == "$expected" ]] ||
    fail "the $label reader mutant returned $rc, expected tripwire code $expected"
}

ss_reader_mutant_case state-filter 74 's|^  /sbin/ss -H -n -t -4$|  /sbin/ss -H -n -t -4 state established|'
ss_reader_mutant_case path-relative 76 's|^  /sbin/ss -H -n -t -4$|  ss -H -n -t -4|'
ss_reader_mutant_case appended-argv 76 's|^  /sbin/ss -H -n -t -4$|  /sbin/ss -H -n -t -4 -p|'
ss_reader_mutant_case appended-command 73 's|^  /sbin/ss -H -n -t -4$|  /sbin/ss -H -n -t -4\n  /sbin/ss -H -n -t -4 dst 0.0.0.0|'
# The mutant injects that seam as literal source text, so it must not expand here.
# shellcheck disable=SC2016
ss_reader_mutant_case override-seam 75 's|^  diene_require_command /sbin/ss$|  diene_require_command "${DIENE_SS_BIN:-/sbin/ss}"|'
ss_reader_mutant_case reader-absent 71 's|^diene_orchestration_ss_observation() {$|diene_renamed_socket_reader() {|'
ok 'the kernel socket reader is the fixed unfiltered absolute /sbin/ss and its tripwire proves each regression'

[[ $(tuple_ss_case 'ESTAB 0 0 10.0.0.2:22 192.0.2.10:4242') == '192.0.2.10 4242 10.0.0.2 22 1 ESTAB 0 0 10.0.0.2:22 192.0.2.10:4242' ]] ||
  fail 'one exact established IPv4 port 22 socket did not yield the orchestration tuple'
[[ $(tuple_ss_case 'ESTAB 0 0 127.0.0.1:6443 127.0.0.1:38122
ESTAB 0 0 10.0.0.2:22 192.0.2.10:4242
ESTAB 0 0 10.142.0.5:443 10.142.0.9:51234') == '192.0.2.10 4242 10.0.0.2 22 1 ESTAB 0 0 10.0.0.2:22 192.0.2.10:4242' ]] ||
  fail 'unrelated established sockets were not ignored while deriving the single port 22 flow'
[[ $(tuple_ss_case 'TIME-WAIT 0 0 10.0.0.2:22 198.51.100.9:5555
SYN-SENT 0 0 10.0.0.2:22 198.51.100.8:5556
ESTAB 0 0 10.0.0.2:22 192.0.2.10:4242') == '192.0.2.10 4242 10.0.0.2 22 1 ESTAB 0 0 10.0.0.2:22 192.0.2.10:4242' ]] ||
  fail 'a non-established port 22 socket was counted as an orchestration flow'
for hostile_observation in '' 'ESTAB 0 0 127.0.0.1:6443 127.0.0.1:38122' \
  'ESTAB 0 0 10.0.0.2:22 192.0.2.10:4242
ESTAB 0 0 10.0.0.2:22 198.51.100.7:5555' \
  'ESTAB 0 0 [fd00::2]:22 [fd00::1]:4242' \
  'ESTAB 0 0 0.0.0.0:22 192.0.2.10:4242' \
  'ESTAB 0 0 10.0.0.2:22 0.0.0.0:4242' \
  'ESTAB 0 0 *:22 192.0.2.10:4242' \
  'ESTAB 0 0 10.0.0.2:2222 192.0.2.10:4242' \
  'ESTAB 0 0 10.0.0.2:ssh 192.0.2.10:4242' \
  'ESTAB 0 0 10.0.0.2:22 192.0.2.10:99999' \
  'ESTAB 0 0 10.0.0.2:22 192.0.2.300:4242' \
  'ESTAB 0 0 10.0.0.2:22 192.0.2.10:4242 users:((sshd,pid=1,fd=3))' \
  'ESTAB 0 0 10.0.0.2:22' \
  'ESTABLISHED 0 0 10.0.0.2:22 192.0.2.10:4242' \
  'SYN-SENT 0 0 10.0.0.2:22 192.0.2.10:4242' \
  'ESTAB x 0 10.0.0.2:22 192.0.2.10:4242' \
  'State Recv-Q Send-Q Local Peer'; do
  expect_refusal InterimPolicyUnavailable tuple_ss_case "$hostile_observation"
done
ok 'the numeric kernel socket parser admits exactly one concrete IPv4 port 22 flow'

kernel_ss_policy_case() {
  local label=${1:?label required} observation=${2:?observation required}
  local mode=${3:-happy}
  local state=$scratch/policy-$label-state evidence=$scratch/policy-$label-evidence
  local tables=$scratch/policy-$label.log
  local staging=$scratch/policy-$label-staging
  local calls=$scratch/policy-$label-reader-calls
  install -d -m 0700 "$state" "$evidence"
  : >"$tables"
  : >"$calls"
  # Hostile staging shapes for the retained-observation artifact. Each one must
  # refuse before any chain exists rather than degrade to an unretained tuple.
  case $mode in
    staging-missing) ;;
    staging-symlink)
      install -d -m 0700 "$scratch/policy-$label-target"
      ln -sfn "$scratch/policy-$label-target" "$staging"
      ;;
    staging-unwritable) install -d -m 0500 "$staging" ;;
    artifact-unsafe)
      install -d -m 0700 "$staging/orchestration/ss-observation.txt"
      ;;
    artifact-target-symlink)
      # A symlinked artifact path pointing at an existing file outside the tree
      # must refuse rather than publish through the link.
      install -d -m 0700 "$staging/orchestration"
      printf 'ORIGINAL\n' >"$scratch/policy-$label-outside"
      ln -sfn "$scratch/policy-$label-outside" "$staging/orchestration/ss-observation.txt"
      ;;
    observation-dir-symlink)
      # A symlinked observation directory would place same-session evidence
      # outside the driver-owned tree while still reporting success.
      install -d -m 0700 "$staging" "$scratch/policy-$label-escape"
      ln -sfn "$scratch/policy-$label-escape" "$staging/orchestration"
      ;;
    *) install -d -m 0700 "$staging" ;;
  esac
  jq -n '{network:{serviceCidrs:["10.143.0.0/16"]}}' >"$evidence/preflight.json"
  (
    cd -- "$work"
    # shellcheck source=/dev/null
    source ./scripts/ci/environment-lib.sh
    diene_validate_inputs
    unset SSH_CONNECTION
    # Production reads the fixed absolute /sbin/ss and exposes no override. Only
    # the reader is replaced here so the parser, retention, and policy path can
    # be driven deterministically; the parser, retention, and every refusal stay
    # the real ones. The exact production argv is proved separately and
    # structurally by assert_fixed_ss_reader; this stub proves how many times the
    # reader is invoked and that production passes it no arguments.
    # The stub reads its inputs from the environment rather than from the
    # caller's locals: production declares its own locals around this call, and a
    # dynamically scoped name would be shadowed by them under `set -u`.
    export FAKE_SS_OBSERVATION="$observation" FAKE_SS_MODE="$mode"
    export FAKE_SS_CALL_LOG="$calls"
    # shellcheck disable=SC2329
    diene_orchestration_ss_observation() {
      printf '[%s]\n' "$*" >>"${FAKE_SS_CALL_LOG:?}"
      [[ ${FAKE_SS_MODE:?} != reader-fail ]] || return 3
      printf '%s\n' "${FAKE_SS_OBSERVATION?}"
    }
    if [[ $mode == staging-relative ]]; then
      export DIENE_EVIDENCE_STAGING="relative/staging"
    else
      export DIENE_EVIDENCE_STAGING="$staging"
    fi
    export DIENE_NSC_CLUSTER_ID="cluster-$label"
    export DIENE_PREFLIGHT_EVIDENCE="$evidence/preflight.json"
    export DIENE_KUBECTL_BIN="$policy_tools/kubectl" DIENE_IPTABLES_BIN="$policy_tools/iptables4"
    export DIENE_IP6TABLES_BIN="$policy_tools/iptables6"
    export DIENE_EGRESS_RESOLVER_BIN="$policy_tools/resolver"
    export DIENE_IPV6_DISABLE_PATH="$ipv6_disabled_path" FAKE_NODE_POD_CIDRS='["10.142.0.0/16"]'
    export FAKE_TABLE_STATE="$state" FAKE_TABLE_LOG="$tables"
    export FAKE_KUBECTL_LOG="$policy_kubectl_log" FAKE_L7_LOG="$policy_l7_log"
    diene_prepare_egress_contract "$evidence/contract.json"
    diene_resolve_egress_contract "$evidence/contract.json" "$evidence/resolved.json"
    diene_apply_interim_policy "$evidence/resolved.json" "$evidence/policy.json" "$evidence/l7.json"
    diene_remove_interim_policy
  ) >"$scratch/policy-$label.out" 2>"$scratch/policy-$label.err"
}

prepare_run 7106
kernel_ss_policy_case kernel-ss 'ESTAB 0 0 127.0.0.1:6443 127.0.0.1:38122
ESTAB 0 0 10.0.0.2:22 192.0.2.10:4242' || {
  sed -n '1,160p' "$scratch/policy-kernel-ss.err" >&2
  fail 'the kernel socket orchestration source refused a valid single observation'
}
jq -e '.orchestrationException == "exact-ssh-4-tuple" and
  .orchestrationTupleSource == "kernel-ss" and .applied == true' \
  "$scratch/policy-kernel-ss-evidence/policy.json" >/dev/null ||
  fail 'the kernel socket transcript lost the exact tuple claim or its recorded source'

# The literal reader ran exactly once, with no arguments, and was not consulted a
# second time for the parse: one observation backs both the rules and the proof.
[[ $(wc -l <"$scratch/policy-kernel-ss-reader-calls") == 1 ]] ||
  fail 'the kernel socket reader was not executed exactly once per policy activation'
[[ $(cat "$scratch/policy-kernel-ss-reader-calls") == '[]' ]] ||
  fail 'production passed arguments to the fixed kernel socket reader'

# The retained artifact is a regular mode-0600 file holding the exact observed
# bytes, and the transcript binds its stable relative name and true digest.
kernel_ss_artifact=$scratch/policy-kernel-ss-staging/orchestration/ss-observation.txt
[[ -f $kernel_ss_artifact && ! -L $kernel_ss_artifact ]] ||
  fail 'the same-session socket observation was not retained as a regular artifact'
[[ $(stat -c %a -- "$kernel_ss_artifact") == 600 ]] ||
  fail 'the retained socket observation is not mode 0600'
[[ $(cat "$kernel_ss_artifact") == 'ESTAB 0 0 127.0.0.1:6443 127.0.0.1:38122
ESTAB 0 0 10.0.0.2:22 192.0.2.10:4242' ]] ||
  fail 'the retained socket observation is not the exact observed bytes'
[[ -z $(find "$scratch/policy-kernel-ss-staging/orchestration" -name '*.tmp.*' -print -quit) ]] ||
  fail 'the retention left a temporary observation file behind'
kernel_ss_artifact_digest="sha256:$(sha256sum -- "$kernel_ss_artifact" | awk '{print $1}')"
jq -e --arg digest "$kernel_ss_artifact_digest" '
  .orchestrationTuple == {clientAddress:"192.0.2.10",clientPort:4242,
    serverAddress:"10.0.0.2",serverPort:22} and
  .orchestrationFlowCount == 1 and
  .orchestrationSelectedRow == "ESTAB 0 0 10.0.0.2:22 192.0.2.10:4242" and
  .orchestrationObservationDigest == $digest and
  .orchestrationObservationArtifact == "orchestration/ss-observation.txt"' \
  "$scratch/policy-kernel-ss-evidence/policy.json" >/dev/null ||
  fail 'the kernel-ss transcript did not bind the retained artifact name, digest, tuple, count, and selected row'
# The bound selected row must be a real, unique line of the retained artifact, so
# a reviewer can point at the exact observed flow without re-running the parser.
kernel_ss_selected_row=$(jq -r '.orchestrationSelectedRow' \
  "$scratch/policy-kernel-ss-evidence/policy.json")
[[ $(grep -Fxc -- "$kernel_ss_selected_row" "$kernel_ss_artifact") == 1 ]] ||
  fail 'the bound selected row is not exactly one line of the retained observation'
grep -Fxq -- "$kernel_ss_selected_row" "$kernel_ss_artifact" ||
  fail 'the bound selected row does not appear verbatim in the retained observation'
# The bound tuple must be the tuple the rules actually used, recomputed from the
# retained bytes rather than taken on trust from the transcript.
[[ $(tuple_ss_case "$(cat "$kernel_ss_artifact")") == '192.0.2.10 4242 10.0.0.2 22 1 ESTAB 0 0 10.0.0.2:22 192.0.2.10:4242' ]] ||
  fail 'reparsing the retained bytes does not reproduce the bound orchestration tuple'
grep -Eq -- '-p tcp -s 10\.0\.0\.2 -d 192\.0\.2\.10 --sport 22 --dport 4242 -m conntrack --ctstate ESTABLISHED -j ACCEPT' \
  "$scratch/policy-kernel-ss.log" ||
  fail 'the kernel socket source did not yield the identical exact four-value SSH rule'
! grep -Fq -- 'ESTABLISHED,RELATED' "$scratch/policy-kernel-ss.log" ||
  fail 'the kernel socket source installed a blanket established-flow exemption'
if grep -Eq -- '0\.0\.0\.0/0|::/0|-d 10\.0\.0\.0/30|--ctstate RELATED|-d 10\.0\.0\.1( |$)' \
  "$scratch/policy-kernel-ss.log"; then
  fail 'the kernel socket source allowed a route, gateway, subnet, or related-flow class'
fi
assert_policy_state_absent "$scratch/policy-kernel-ss-state" kernel-ss

prepare_run 7107
if kernel_ss_policy_case kernel-ss-zero 'ESTAB 0 0 127.0.0.1:6443 127.0.0.1:38122'; then
  fail 'a kernel socket table without an established port 22 flow activated policy'
fi
grep -Fq -- InterimPolicyUnavailable "$scratch/policy-kernel-ss-zero.err" ||
  fail 'the degenerate kernel socket observation lost its stable refusal'
[[ ! -e $scratch/policy-kernel-ss-zero-evidence/policy.json ]] ||
  fail 'a refused tuple observation still emitted a policy transcript'
assert_policy_state_absent "$scratch/policy-kernel-ss-zero-state" kernel-ss-zero
ok 'both orchestration tuple sources yield the same exact rule and refuse before any mutation'

# Every way the same-session retention can fail must refuse before any chain,
# hook, or transcript exists, rather than fall back to an unretained tuple.
kernel_ss_refusal_case() {
  local label=${1:?label required} mode=${2:?mode required}
  local observation=${3:-'ESTAB 0 0 10.0.0.2:22 192.0.2.10:4242'}
  prepare_run "$4"
  if kernel_ss_policy_case "$label" "$observation" "$mode"; then
    fail "the $mode kernel socket observation activated policy"
  fi
  grep -Fq -- InterimPolicyUnavailable "$scratch/policy-$label.err" ||
    fail "the $mode observation lost its stable InterimPolicyUnavailable refusal"
  [[ ! -e $scratch/policy-$label-evidence/policy.json ]] ||
    fail "the $mode observation still emitted a policy transcript"
  assert_policy_state_absent "$scratch/policy-$label-state" "$label"
}

kernel_ss_refusal_case kernel-ss-reader-fail reader-fail \
  'ESTAB 0 0 10.0.0.2:22 192.0.2.10:4242' 7140
kernel_ss_refusal_case kernel-ss-staging-missing staging-missing \
  'ESTAB 0 0 10.0.0.2:22 192.0.2.10:4242' 7141
kernel_ss_refusal_case kernel-ss-staging-relative staging-relative \
  'ESTAB 0 0 10.0.0.2:22 192.0.2.10:4242' 7142
kernel_ss_refusal_case kernel-ss-staging-symlink staging-symlink \
  'ESTAB 0 0 10.0.0.2:22 192.0.2.10:4242' 7143
kernel_ss_refusal_case kernel-ss-staging-unwritable staging-unwritable \
  'ESTAB 0 0 10.0.0.2:22 192.0.2.10:4242' 7144
kernel_ss_refusal_case kernel-ss-artifact-unsafe artifact-unsafe \
  'ESTAB 0 0 10.0.0.2:22 192.0.2.10:4242' 7145
kernel_ss_refusal_case kernel-ss-dir-symlink observation-dir-symlink \
  'ESTAB 0 0 10.0.0.2:22 192.0.2.10:4242' 7148
# The refusal must also mean nothing was written through the symlink.
[[ -z $(find "$scratch/policy-kernel-ss-dir-symlink-escape" -type f -print -quit 2>/dev/null) ]] ||
  fail 'a symlinked observation directory let same-session evidence escape the driver-owned tree'
kernel_ss_refusal_case kernel-ss-target-symlink artifact-target-symlink \
  'ESTAB 0 0 10.0.0.2:22 192.0.2.10:4242' 7149
[[ $(cat "$scratch/policy-kernel-ss-target-symlink-outside") == ORIGINAL ]] ||
  fail 'a symlinked observation target let the retention publish through the link'
kernel_ss_refusal_case kernel-ss-multiple multiple \
  'ESTAB 0 0 10.0.0.2:22 192.0.2.10:4242
ESTAB 0 0 10.0.0.2:22 198.51.100.7:5555' 7146
kernel_ss_refusal_case kernel-ss-malformed malformed \
  'ESTAB 0 0 10.0.0.2:22 192.0.2.10:4242 users:((sshd,pid=1,fd=3))' 7147
# A refused observation must not leave a half-written or world-readable artifact.
for refused_label in kernel-ss-reader-fail kernel-ss-multiple kernel-ss-malformed \
  kernel-ss-artifact-unsafe kernel-ss-target-symlink; do
  refused_artifact=$scratch/policy-$refused_label-staging/orchestration
  if [[ -d $refused_artifact ]]; then
    [[ -z $(find "$refused_artifact" -name '*.tmp.*' -print -quit) ]] ||
      fail "the refused $refused_label observation left a temporary artifact behind"
    while IFS= read -r retained; do
      [[ $(stat -c %a -- "$retained") == 600 ]] ||
        fail "the refused $refused_label observation left a non-0600 artifact"
    done < <(find "$refused_artifact" -type f)
  fi
done
chmod -R u+rwX "$scratch/policy-kernel-ss-staging-unwritable-staging" 2>/dev/null || true
ok 'observation, staging, retention, and parse failures all refuse before any policy artifact exists'

printf '== the fixed remote command pins and verifies guest nix ==\n'

nix_guard_probe=$scratch/nix-guard-probe.sh
{
  printf '%s\n' '#!/usr/bin/env bash' 'set -eu'
  printf '%s\n' "$guest_nix_guard"
  printf '%s\n' 'printf "GuestNixToolchainPresent\n"'
} >"$nix_guard_probe"
chmod 0755 "$nix_guard_probe"
nix_guard_bin=$scratch/nix-guard-bin
install -d -m 0700 "$nix_guard_bin"
nix_guard_rc=0
env -i "PATH=$nix_guard_bin" "$BASH" "$nix_guard_probe" \
  >"$scratch/nix-guard-absent.out" 2>"$scratch/nix-guard-absent.err" || nix_guard_rc=$?
[[ $nix_guard_rc == 64 ]] ||
  fail "the fixed guest nix guard did not refuse an absent toolchain with the stable reason exit (got $nix_guard_rc)"
grep -Fq -- 'GuestNixToolchainAbsent:' "$scratch/nix-guard-absent.err" ||
  fail 'the absent guest toolchain produced no stable GuestNixToolchainAbsent diagnostic'
[[ ! -s $scratch/nix-guard-absent.out ]] ||
  fail 'the refused guest entry still produced driver output'
printf '%s\n' '#!/bin/sh' 'exit 0' >"$nix_guard_bin/nix"
chmod 0755 "$nix_guard_bin/nix"
env -i "PATH=$nix_guard_bin" "$BASH" "$nix_guard_probe" \
  >"$scratch/nix-guard-present.out" 2>"$scratch/nix-guard-present.err" ||
  fail 'the guest nix guard refused an instance that does provide nix'
grep -Fxq -- GuestNixToolchainPresent "$scratch/nix-guard-present.out" ||
  fail 'the guest nix guard did not fall through to the driver entry'
# Refined-by the generation-9 direct-binary ruling: preserve the old blanket
# bootstrap guard's intent while admitting only the two exact immutable tagged
# assets. The harness carries hostile tokens, so scan production files only.
# Join shell continuations before matching, retain a non-whitespace boundary
# between files, and scan pipe continuations in multiline mode. A forbidden
# command therefore cannot evade the scan by moving onto the next physical
# line, and two unrelated files cannot combine into one synthetic command. The
# shell-command token boundary excludes the `.sh` suffix in a benign helper.
guest_nix_production_normalized=$scratch/guest-nix-production-normalized
: >"$guest_nix_production_normalized"
while IFS= read -r guest_nix_production_file; do
  sed ':join; /\\$/ { N; s/\\\n[[:space:]]*/ /; b join; }' \
    "$guest_nix_production_file" >>"$guest_nix_production_normalized"
  printf '\nDIENE_GUEST_NIX_FILE_BOUNDARY\n' >>"$guest_nix_production_normalized"
done < <(find "$template_root/scripts/ci" -type f -name '*.sh' ! -name 'test-*.sh' -print | LC_ALL=C sort)

guest_nix_pipe_shell_regex='curl[^\r\n|]*\|[[:space:]]*(sh|bash)($|[;&|<>[:space:]])'
guest_nix_bootstrap_regex="${guest_nix_pipe_shell_regex}"'|nixos\.org/nix/install|DeterminateSystems/nix-installer-action|install\.determinate\.systems/nix($|[^/[:alnum:]._-])'
if rg -n -U "$guest_nix_bootstrap_regex" \
  "$guest_nix_production_normalized" >"$scratch/guest-nix-bootstrap"; then
  sed -n '1,120p' "$scratch/guest-nix-bootstrap" >&2
  fail 'the driver rail contains a pipe-to-shell, rolling, upstream, or action bootstrap path'
fi
guest_nix_execution_regex='(^|[^[:alnum:]_.-])(sh|bash)[[:space:]]+[^;|&]*guest-nix-bootstrap\.sh|guest-nix-bootstrap\.sh[[:space:]]+install|guest-nix-installer[[:space:]]+install[^;[:cntrl:]]*(--nix-package-url|--prefer-upstream|--force|--plan)'
if rg -n "$guest_nix_execution_regex" "$guest_nix_production_normalized" \
  >"$scratch/guest-nix-execution-overrides"; then
  sed -n '1,120p' "$scratch/guest-nix-execution-overrides" >&2
  fail 'the production rail executes the provenance shell or changes the pinned installer argv'
fi
printf '%s\n' 'guest_nix_pinned_asset_valid guest-nix-bootstrap.sh guest-nix-bootstrap.sha256' \
  >"$scratch/guest-nix-guard-safe"
if rg -q "$guest_nix_execution_regex" "$scratch/guest-nix-guard-safe"; then
  fail 'the provenance-shell execution scan mistakes a sidecar helper argument for a shell command'
fi
printf '%s\n' "sh \\" '  ./guest-nix-bootstrap.sh install linux --no-confirm --init none' \
  >"$scratch/guest-nix-guard-continuation"
sed ':join; /\\$/ { N; s/\\\n[[:space:]]*/ /; b join; }' \
  "$scratch/guest-nix-guard-continuation" >"$scratch/guest-nix-guard-continuation.normalized"
rg -q "$guest_nix_execution_regex" "$scratch/guest-nix-guard-continuation.normalized" ||
  fail 'a backslash-newline provenance-shell execution evaded the production scan'
printf '%s\n' 'curl https://example.invalid/install |' '  sh' \
  >"$scratch/guest-nix-guard-pipe-newline"
rg -U -q "$guest_nix_pipe_shell_regex" "$scratch/guest-nix-guard-pipe-newline" ||
  fail 'a pipe-newline shell execution evaded the production scan'
printf '%s\n' 'curl https://example.invalid/data | sidecar-helper.sh --check' \
  >"$scratch/guest-nix-guard-pipe-helper"
if rg -U -q "$guest_nix_pipe_shell_regex" "$scratch/guest-nix-guard-pipe-helper"; then
  fail 'the pipe-to-shell scan mistakes a .sh helper suffix for a shell command token'
fi
pinned_shell_url='https://install.'
pinned_shell_url+='determinate.systems/nix/tag/v3.21.9'
pinned_payload_url="$pinned_shell_url/nix-installer-x86_64-linux"
pinned_shell_digest='sha256:ed6067b13423cfd36c50e5b156b9e08e'
pinned_shell_digest+='b3a7bea4dde8cb1c8d997d757b37b7f6'
pinned_payload_digest='sha256:58cf15422853e95187405d66b0cdb306'
pinned_payload_digest+='e66f602218ee0032386c46b1b776a6d1'
production_lib=$template_root/scripts/ci/environment-lib.sh
[[ $(grep -Fxc -- "DIENE_GUEST_NIX_INSTALLER_URL=$pinned_shell_url" "$production_lib") == 1 &&
  $(grep -Fxc -- "DIENE_GUEST_NIX_PAYLOAD_URL=$pinned_payload_url" "$production_lib") == 1 &&
  $(grep -Fxc -- "DIENE_GUEST_NIX_INSTALLER_DIGEST=$pinned_shell_digest" "$production_lib") == 1 &&
  $(grep -Fxc -- "DIENE_GUEST_NIX_PAYLOAD_DIGEST=$pinned_payload_digest" "$production_lib") == 1 ]] ||
  fail 'the exact tagged guest Nix URLs and full digests are not unique pinned constants'
[[ $(rg -F --glob '!test-*.sh' 'install.determinate.systems' "$template_root/scripts/ci" | wc -l) == 2 ]] ||
  fail 'an unreviewed Determinate installer URL exists outside the two exact pinned constants'
[[ $(rg -F --glob '!test-*.sh' "$pinned_shell_digest" "$template_root/scripts/ci" | wc -l) == 1 &&
  $(rg -F --glob '!test-*.sh' "$pinned_payload_digest" "$template_root/scripts/ci" | wc -l) == 1 ]] ||
  fail 'a guest Nix digest is duplicated outside its single source-of-truth constant'
production_remote_command=$scratch/guest-nix-production-remote-command
(
  # shellcheck source=/dev/null
  source "$template_root/scripts/ci/environment-k3d-run.sh"
  orchestrator_fixed_remote_command
) >"$production_remote_command"
[[ $(grep -Fxc -- "guest_nix_installer_digest=$pinned_shell_digest" "$production_remote_command") == 1 &&
  $(grep -Fxc -- 'guest_nix_installer_bytes=19299' "$production_remote_command") == 1 &&
  $(grep -Fxc -- "guest_nix_payload_digest=$pinned_payload_digest" "$production_remote_command") == 1 &&
  $(grep -Fxc -- 'guest_nix_payload_bytes=73234640' "$production_remote_command") == 1 ]] ||
  fail 'the materialized fixed remote command is not bound to all four centrally validated pins'
! rg -q '__DIENE_GUEST_NIX_' "$production_remote_command" ||
  fail 'the materialized fixed remote command retained an unresolved pin placeholder'
remote_bootstrap_pin_line=$(rg -n '^guest_nix_pinned_asset_valid guest-nix-bootstrap\.sh ' \
  "$production_remote_command" | cut -d: -f1)
remote_payload_pin_line=$(rg -n '^  guest_nix_pinned_asset_valid guest-nix-installer ' \
  "$production_remote_command" | cut -d: -f1)
remote_payload_chmod_line=$(rg -n '^chmod 0500 guest-nix-installer$' \
  "$production_remote_command" | cut -d: -f1)
remote_installer_version_line=$(rg -n '^if ! \./guest-nix-installer --version ' \
  "$production_remote_command" | cut -d: -f1)
remote_installer_validation_line=$(rg -n '^guest_nix_exact_output_valid ' \
  "$production_remote_command" | cut -d: -f1)
remote_install_line=$(rg -n "^NIX_INSTALLER_DIAGNOSTIC_ENDPOINT='' ./guest-nix-installer install " \
  "$production_remote_command" | cut -d: -f1)
for remote_boundary in "$remote_bootstrap_pin_line" "$remote_payload_pin_line" \
  "$remote_payload_chmod_line" "$remote_installer_version_line" \
  "$remote_installer_validation_line" "$remote_install_line"; do
  [[ $remote_boundary =~ ^[1-9][0-9]*$ ]] ||
    fail 'a fixed remote pin/version/install boundary is absent or ambiguous'
done
[[ $remote_bootstrap_pin_line -lt $remote_payload_pin_line &&
  $remote_payload_pin_line -lt $remote_payload_chmod_line &&
  $remote_payload_chmod_line -lt $remote_installer_version_line &&
  $remote_installer_version_line -lt $remote_installer_validation_line &&
  $remote_installer_validation_line -lt $remote_install_line ]] ||
  fail 'fixed remote pin validation does not precede chmod, raw --version validation, and install'
# The fixed remote source is matched literally, not expanded by this harness.
# shellcheck disable=SC2016
remote_installer_probe_source='if ! ./guest-nix-installer --version >"$installer_version_stdout" 2>"$installer_version_stderr"; then'
if ! grep -Fqx -- 'installer_version_stdout=evidence/guest-nix/installer-version.txt' \
  "$production_remote_command" ||
  ! grep -Fqx -- 'installer_version_stderr=evidence/guest-nix/installer-version.stderr' \
    "$production_remote_command" ||
  ! grep -Fqx -- "$remote_installer_probe_source" "$production_remote_command"; then
  fail 'the fixed remote command does not retain raw installer stdout and stderr separately'
fi
! rg -q 'installer_version[[:space:]]*=\$\(' "$production_remote_command" ||
  fail 'the installer version proof regressed to newline-normalizing command substitution'

remote_exact_output_helper=$scratch/guest-nix-exact-output-helper.sh
sed -n '/^guest_nix_exact_output_valid() {$/,/^}$/p' \
  "$production_remote_command" >"$remote_exact_output_helper"
[[ $(grep -c '^guest_nix_exact_output_valid() {$' "$remote_exact_output_helper") == 1 ]] ||
  fail 'the exact installer output helper could not be isolated from the fixed remote command'
# shellcheck source=/dev/null
source "$remote_exact_output_helper"
guest_nix_remote_output_case() {
  local label=${1:?output case required} shape=${2:?output shape required}
  local expect=${3:?output expectation required}
  local stdout_file=$scratch/guest-nix-installer-output-$label.stdout
  local stderr_file=$scratch/guest-nix-installer-output-$label.stderr result=refuse
  : >"$stdout_file"
  : >"$stderr_file"
  case $shape in
    exact) printf '%s\n' 'nix-installer 3.21.9' >"$stdout_file" ;;
    wrong) printf '%s\n' 'nix-installer 3.21.8' >"$stdout_file" ;;
    empty) ;;
    multiline) printf '%s\n%s\n' 'nix-installer 3.21.9' extra >"$stdout_file" ;;
    extra-newline) printf 'nix-installer 3.21.9\n\n' >"$stdout_file" ;;
    stderr)
      printf '%s\n' 'nix-installer 3.21.9' >"$stdout_file"
      printf '%s\n' warning >"$stderr_file"
      ;;
    *) fail "unknown exact installer output shape $shape" ;;
  esac
  if guest_nix_exact_output_valid "$stdout_file" "$stderr_file" \
    'nix-installer 3.21.9' 21; then
    result=accept
  fi
  [[ $result == "$expect" ]] ||
    fail "$label installer output was $result instead of $expect"
}
guest_nix_remote_output_case exact exact accept
guest_nix_remote_output_case wrong wrong refuse
guest_nix_remote_output_case empty empty refuse
guest_nix_remote_output_case multiline multiline refuse
guest_nix_remote_output_case extra-newline extra-newline refuse
guest_nix_remote_output_case stderr stderr refuse

remote_profile_helper=$scratch/guest-nix-source-profile-helper.sh
sed -n '/^guest_nix_source_profile() {$/,/^}$/p' \
  "$production_remote_command" >"$remote_profile_helper"
[[ $(grep -c '^guest_nix_source_profile() {$' "$remote_profile_helper") == 1 ]] ||
  fail 'the profile source helper could not be isolated from the fixed remote command'
# shellcheck source=/dev/null
source "$remote_profile_helper"
hostile_guest_nix_profile=$scratch/hostile-guest-nix-profile.sh
# The hostile profile must expand its inherited PATH only when it is sourced.
# shellcheck disable=SC2016
printf '%s\n' 'PATH=/hostile-profile/bin:$PATH' 'export PATH' 'return 23' \
  >"$hostile_guest_nix_profile"
remote_profile_original_path=$PATH
remote_profile_rc=0
if guest_nix_source_profile "$hostile_guest_nix_profile"; then
  fail 'the fixed remote profile helper accepted a nonzero source result'
else
  remote_profile_rc=$?
fi
remote_profile_flags=$-
[[ $remote_profile_rc == 23 && $PATH == /hostile-profile/bin:* &&
  $remote_profile_flags == *e* && $remote_profile_flags == *u* ]] ||
  fail 'the fixed remote profile helper lost source status, profile state, or strict flags'
PATH=$remote_profile_original_path

remote_profile_line=$(rg -n '^  guest_nix_source_profile ' \
  "$production_remote_command" | cut -d: -f1)
remote_profile_refusal_line=$(rg -n '^    guest_nix_fail GuestNixProfileSourceFailed ' \
  "$production_remote_command" | cut -d: -f1)
remote_develop_line=$(rg -n '^exec /nix/var/nix/profiles/default/bin/nix .* develop ' \
  "$production_remote_command" | cut -d: -f1)
for remote_boundary in "$remote_profile_line" "$remote_profile_refusal_line" "$remote_develop_line"; do
  [[ $remote_boundary =~ ^[1-9][0-9]*$ ]] ||
    fail 'a fixed remote profile/develop boundary is absent or ambiguous'
done
[[ $remote_profile_line -lt $remote_profile_refusal_line &&
  $remote_profile_refusal_line -lt $remote_develop_line ]] ||
  fail 'the fixed remote command does not refuse a failed profile source before nix develop'

profile_refusal_marker=$scratch/guest-nix-host-profile-protected-mutation
profile_refusal_rc=0
if (
  # shellcheck source=/dev/null
  source "$template_root/scripts/ci/environment-lib.sh"
  diene_source_guest_nix_profile "$hostile_guest_nix_profile"
  : >"$profile_refusal_marker"
) >"$scratch/guest-nix-host-profile.out" 2>"$scratch/guest-nix-host-profile.err"; then
  fail 'the shared profile verifier accepted a nonzero source result'
else
  profile_refusal_rc=$?
fi
[[ $profile_refusal_rc == 64 ]] ||
  fail "the shared profile verifier did not exit 64 (got $profile_refusal_rc)"
grep -Fq -- 'GuestNixProfileSourceFailed:' "$scratch/guest-nix-host-profile.err" ||
  fail 'the shared profile verifier emitted no stable profile-source refusal'
[[ ! -e $profile_refusal_marker ]] ||
  fail 'a failed profile source reached a protected mutation'
ok 'raw installer bytes and successful profile sourcing are proved before install or develop'

nix_guard_binding_root=$scratch/nix-guard-binding
install -d -m 0700 "$nix_guard_binding_root/instances/cluster-0000000000000000/fs"
: >"$nix_guard_binding_root/instances/cluster-0000000000000000/live"
nix_guard_binding_rc=0
FAKE_NSC_ROOT=$nix_guard_binding_root FAKE_NSC_LOG=$nix_guard_binding_root/log \
  FAKE_GUEST_NIX_GUARD=$guest_nix_guard FAKE_GUEST_BIN=$fake_guest \
  "$fake_nsc" ssh cluster-0000000000000000 -T \
  'set -eu; sha256sum -c archive-validator.sha256; ./archive-validator.sh source.tar source; exec nix develop' \
  >/dev/null 2>&1 || nix_guard_binding_rc=$?
[[ $nix_guard_binding_rc == 69 ]] ||
  fail 'the fake ssh leg does not bind the fixed guest nix guard to production text'
ok 'the fixed rail preserves GuestNixToolchainAbsent while admitting only exact direct-binary pins'

printf '== pinned guest Nix bootstrap fails closed ==\n'

guest_nix_work_lib=$work/scripts/ci/environment-lib.sh
guest_nix_work_lib_backup=$scratch/environment-lib.guest-nix-good.sh
cp "$guest_nix_work_lib" "$guest_nix_work_lib_backup"

guest_nix_invalid_contract_case() {
  local run_id=${1:?run id required} mutation=${2:?contract mutation required}
  cp "$guest_nix_work_lib_backup" "$guest_nix_work_lib"
  case $mutation in
    rolling-url)
      sed -i 's|^DIENE_GUEST_NIX_INSTALLER_URL=.*|DIENE_GUEST_NIX_INSTALLER_URL=https://install.determinate.systems/nix|' \
        "$guest_nix_work_lib"
      ;;
    unpinned-payload)
      sed -i 's|^DIENE_GUEST_NIX_PAYLOAD_URL=.*|DIENE_GUEST_NIX_PAYLOAD_URL=https://install.determinate.systems/nix/tag/v3.21.9/other|' \
        "$guest_nix_work_lib"
      ;;
    short-digest)
      sed -i 's|^DIENE_GUEST_NIX_INSTALLER_DIGEST=.*|DIENE_GUEST_NIX_INSTALLER_DIGEST=sha256:abcd|' \
        "$guest_nix_work_lib"
      ;;
    malformed-bytes)
      sed -i 's|^DIENE_GUEST_NIX_PAYLOAD_BYTES=.*|DIENE_GUEST_NIX_PAYLOAD_BYTES=not-a-number|' \
        "$guest_nix_work_lib"
      ;;
    wrong-architecture)
      sed -i 's|^DIENE_GUEST_NIX_ARCH=.*|DIENE_GUEST_NIX_ARCH=aarch64|' "$guest_nix_work_lib"
      ;;
    *) fail "unknown guest Nix contract mutation $mutation" ;;
  esac
  prepare_run "$run_id"
  expect_precreate_refusal InputContractInvalid env ./scripts/ci/environment-k3d-run.sh orchestrate
  cp "$guest_nix_work_lib_backup" "$guest_nix_work_lib"
}

guest_nix_invalid_contract_case 7301 rolling-url
guest_nix_invalid_contract_case 7302 unpinned-payload
guest_nix_invalid_contract_case 7303 short-digest
guest_nix_invalid_contract_case 7304 malformed-bytes
guest_nix_invalid_contract_case 7305 wrong-architecture

guest_nix_contract_value_refusal() {
  local label=${1:?label required} rc=0
  if (
    # shellcheck source=/dev/null
    source "$guest_nix_work_lib_backup"
    case $label in
      empty-identity) DIENE_GUEST_NIX_EXPECTED_IDENTITY= ;;
      multiline-identity) DIENE_GUEST_NIX_EXPECTED_IDENTITY=$'nix (Determinate Nix 3.21.9) 2.34.8\nextra' ;;
      wrong-mode) DIENE_GUEST_NIX_EXECUTION_MODE=shell-bootstrap ;;
      *) exit 127 ;;
    esac
    export DIENE_GUEST_NIX_EXPECTED_IDENTITY DIENE_GUEST_NIX_EXECUTION_MODE
    diene_guest_nix_contract
  ) >"$scratch/guest-nix-contract-$label.out" 2>"$scratch/guest-nix-contract-$label.err"; then
    fail "$label guest Nix contract unexpectedly passed"
  else
    rc=$?
  fi
  [[ $rc == 64 ]] || fail "$label guest Nix contract did not exit 64"
  assert_contains "$scratch/guest-nix-contract-$label.err" InputContractInvalid
}
guest_nix_contract_value_refusal empty-identity
guest_nix_contract_value_refusal multiline-identity
guest_nix_contract_value_refusal wrong-mode
ok 'rolling, unpinned, malformed, non-x86_64, empty, multiline, and shell-mode contracts refuse before create'

guest_nix_fetch_refusal() {
  local run_id=${1:?run id required} scenario=${2:?fetch scenario required}
  prepare_run "$run_id"
  expect_precreate_refusal GuestNixInstallerUntrusted env \
    FAKE_GUEST_NIX_FETCH_SCENARIO="$scenario" ./scripts/ci/environment-k3d-run.sh orchestrate
  ! find "$RUNNER_TEMP" -name '*.tmp.*' -print -quit | grep -q . ||
    fail "$scenario left a private acquisition temporary file"
  ! find "$RUNNER_TEMP" -name 'guest-nix-*.sha256' -print -quit | grep -q . ||
    fail "$scenario published sidecars before both artifacts verified"
}
guest_nix_fetch_refusal 7310 redirect
guest_nix_fetch_refusal 7311 transport-fail
guest_nix_fetch_refusal 7312 installer-short
guest_nix_fetch_refusal 7313 installer-digest
guest_nix_fetch_refusal 7314 payload-short
guest_nix_fetch_refusal 7315 payload-digest
ok 'redirect, transport, byte-count, and full-digest failures leave zero creates and no partial publication'

guest_nix_publication_refusal() {
  local label=${1:?publication label required} shape=${2:?publication shape required}
  local root=$scratch/guest-nix-publication-$label outside=$scratch/guest-nix-publication-$label-outside
  local target curl_log=$scratch/guest-nix-publication-$label.curl rc=0
  install -d -m 0700 "$root" "$outside"
  : >"$curl_log"
  case $shape in
    target-symlink)
      install -d -m 0700 "$root/publish"
      printf '%s\n' sentinel >"$outside/sentinel"
      ln -s "$outside/sentinel" "$root/publish/guest-nix-bootstrap.sh"
      target=$root/publish/guest-nix-bootstrap.sh
      ;;
    parent-symlink)
      ln -s "$outside" "$root/publish"
      target=$root/publish/guest-nix-bootstrap.sh
      ;;
    *) fail "unknown guest Nix publication shape $shape" ;;
  esac
  if (
    # shellcheck source=/dev/null
    source "$guest_nix_work_lib_backup"
    export DIENE_CURL_BIN=$fake_guest_nix_curl FAKE_GUEST_NIX_CURL_LOG=$curl_log
    export FAKE_GUEST_NIX_SOURCE_DIR=$guest_nix_fixture_dir
    diene_fetch_pinned_artifact "$DIENE_GUEST_NIX_INSTALLER_URL" \
      "$DIENE_GUEST_NIX_INSTALLER_DIGEST" "$DIENE_GUEST_NIX_INSTALLER_BYTES" "$target"
  ) >"$root.out" 2>"$root.err"; then
    fail "$label hostile publication target unexpectedly passed"
  else
    rc=$?
  fi
  [[ $rc == 64 ]] || fail "$label hostile publication target did not exit 64"
  assert_contains "$root.err" GuestNixInstallerUntrusted
  [[ ! -s $curl_log ]] || fail "$label fetched before refusing the hostile publication target"
  [[ -z $(find "$root" -name '*.tmp.*' -print -quit) ]] ||
    fail "$label left a private publication temporary file"
  case $shape in
    target-symlink)
      [[ -L $target && $(<"$outside/sentinel") == sentinel ]] ||
        fail 'the target-symlink refusal replaced the link or changed its outside referent'
      ;;
    parent-symlink)
      [[ -L $root/publish && ! -e $outside/guest-nix-bootstrap.sh ]] ||
        fail 'the parent-symlink refusal published outside the private target directory'
      ;;
  esac
}
guest_nix_publication_refusal symlink-target target-symlink
guest_nix_publication_refusal symlink-parent parent-symlink
ok 'host acquisition refuses linked publication targets and parents before fetch or outside write'

guest_nix_remote_refusal() {
  local run_id=${1:?run id required} scenario=${2:?remote scenario required}
  local inner_reason=${3:?inner reason required} rc=0
  prepare_run "$run_id"
  local runner=$RUNNER_TEMP nsc_root=$FAKE_NSC_ROOT event_log=$FAKE_GUEST_NIX_EVENT_LOG
  if run_orchestrator "$scenario" >"$scratch/guest-remote-$scenario.out" \
    2>"$scratch/guest-remote-$scenario.err"; then
    fail "$scenario guest Nix refusal unexpectedly passed"
  else
    rc=$?
  fi
  ((rc != 0)) || fail "$scenario guest Nix refusal returned zero"
  assert_contains "$scratch/guest-remote-$scenario.err" NamespaceSshDriverFailed
  local remote_stderr
  remote_stderr=$(find "$runner/diene-namespace" -path '*/staging/stderr' -print -quit)
  [[ -n $remote_stderr ]] || fail "$scenario retained no SSH stderr evidence"
  assert_contains "$remote_stderr" "$inner_reason"
  ! grep -Fxq -- nix-develop "$event_log" || fail "$scenario reached nix develop"
  local expect_version=false expect_install=false expect_profile=false
  case $scenario in
    guest-wrong-arch | guest-preexisting | guest-upload-*) ;;
    guest-wrong-installer-version | guest-empty-installer-version | \
      guest-multiline-installer-version | guest-extra-newline-installer-version | \
      guest-installer-version-stderr)
      expect_version=true
      ;;
    guest-installer-fail)
      expect_version=true
      expect_install=true
      ;;
    guest-profile-source-fail | guest-toolchain-absent)
      expect_version=true
      expect_install=true
      expect_profile=true
      ;;
    *) fail "missing event-boundary expectation for $scenario" ;;
  esac
  if [[ $expect_version == true ]]; then
    [[ $(grep -Fxc -- installer-version-probe "$event_log") == 1 ]] ||
      fail "$scenario did not reach its one allowed installer --version boundary"
  else
    ! grep -Fxq -- installer-version-probe "$event_log" ||
      fail "$scenario reached forbidden installer --version"
  fi
  if [[ $expect_install == true ]]; then
    [[ $(grep -Fxc -- 'installer-argv install linux --no-confirm --init none' "$event_log") == 1 ]] ||
      fail "$scenario did not reach its one allowed installer install boundary"
  else
    ! grep -Eq '^installer-argv( |$)' "$event_log" ||
      fail "$scenario reached forbidden installer install"
  fi
  if [[ $expect_profile == true ]]; then
    [[ $(grep -Fxc -- profile-source "$event_log") == 1 ]] ||
      fail "$scenario did not reach its one allowed profile-source boundary"
  else
    ! grep -Fxq -- profile-source "$event_log" ||
      fail "$scenario reached forbidden profile sourcing"
  fi
  local version_event_line=0 install_event_line=0 profile_event_line=0
  if [[ $expect_version == true ]]; then
    version_event_line=$(grep -nFx -- installer-version-probe "$event_log" | cut -d: -f1)
  fi
  if [[ $expect_install == true ]]; then
    install_event_line=$(grep -nFx -- 'installer-argv install linux --no-confirm --init none' \
      "$event_log" | cut -d: -f1)
    [[ $version_event_line -lt $install_event_line ]] ||
      fail "$scenario installer install did not follow its version probe"
  fi
  if [[ $expect_profile == true ]]; then
    profile_event_line=$(grep -nFx -- profile-source "$event_log" | cut -d: -f1)
    [[ $install_event_line -lt $profile_event_line ]] ||
      fail "$scenario profile source did not follow its installer invocation"
  fi
  local cluster
  cluster=$(find "$nsc_root/instances" -name meta.json -exec jq -r '.cluster_id' {} \;)
  [[ $(grep -Ec "^destroy --force ${cluster} " "$FAKE_NSC_LOG") == 1 &&
    ! -e $nsc_root/instances/$cluster/live ]] ||
    fail "$scenario did not preserve exact destroy and absence"
}

guest_nix_remote_refusal 7320 guest-wrong-arch GuestNixInstallerUnsupportedArch
guest_nix_remote_refusal 7321 guest-preexisting GuestNixPreexistingState
guest_nix_remote_refusal 7322 guest-upload-bootstrap-tamper GuestNixInstallerUntrusted
guest_nix_remote_refusal 7323 guest-upload-payload-tamper GuestNixInstallerUntrusted
guest_nix_remote_refusal 7324 guest-upload-sidecar-tamper GuestNixInstallerUntrusted
guest_nix_remote_refusal 7328 guest-upload-bootstrap-pair-tamper GuestNixInstallerUntrusted
guest_nix_remote_refusal 7329 guest-upload-payload-pair-tamper GuestNixInstallerUntrusted
guest_nix_remote_refusal 7330 guest-upload-payload-symlink GuestNixInstallerUntrusted
guest_nix_remote_refusal 7325 guest-wrong-installer-version GuestNixInstallerUntrusted
guest_nix_remote_refusal 7331 guest-empty-installer-version GuestNixInstallerUntrusted
guest_nix_remote_refusal 7332 guest-multiline-installer-version GuestNixInstallerUntrusted
guest_nix_remote_refusal 7333 guest-extra-newline-installer-version GuestNixInstallerUntrusted
guest_nix_remote_refusal 7334 guest-installer-version-stderr GuestNixInstallerUntrusted
guest_nix_remote_refusal 7326 guest-installer-fail GuestNixInstallFailed
guest_nix_remote_refusal 7335 guest-profile-source-fail GuestNixProfileSourceFailed
guest_nix_remote_refusal 7327 guest-toolchain-absent GuestNixToolchainAbsent
ok 'every remote refusal stops at its exact version, install, profile, and develop event boundary'

guest_nix_identity_probe() (
  local mode=${1:?identity mode required} root=${2:?identity root required}
  # shellcheck source=/dev/null
  source "$guest_nix_work_lib_backup"
  local evidence=$root/evidence/guest-nix store_root=$root/nix/store
  local store_bin=$store_root/synthetic-determinate/bin/nix
  local nix_bin=$root/nix/var/nix/profiles/default/bin/nix
  local installed_copy=$root/nix/nix-installer
  local bootstrap=$root/run/diene-ci/guest-nix-bootstrap.sh
  local payload=$root/run/diene-ci/guest-nix-installer input=$root/run/diene-ci/inputs.json
  install -d -m 0700 "$evidence" "$(dirname -- "$store_bin")" "$(dirname -- "$nix_bin")" \
    "$(dirname -- "$installed_copy")" "$(dirname -- "$bootstrap")"
  cat >"$store_bin" <<'NIX'
#!/bin/sh
case ${FAKE_IDENTITY_MODE:-happy} in
  wrong-version) printf '%s\n' 'nix (Determinate Nix 3.21.9) 2.34.7' ;;
  empty) : ;;
  multiline) printf '%s\n%s\n' 'nix (Determinate Nix 3.21.9) 2.34.8' extra ;;
  *) printf '%s\n' 'nix (Determinate Nix 3.21.9) 2.34.8' ;;
esac
NIX
  chmod 0500 "$store_bin"
  ln -s "$store_bin" "$nix_bin"
  cp "$guest_nix_fixture_dir/guest-nix-bootstrap.sh" "$bootstrap"
  cp "$guest_nix_fixture_dir/guest-nix-installer" "$payload"
  cp "$payload" "$installed_copy"
  chmod 0600 "$bootstrap" "$payload" "$installed_copy"
  printf '%s\n' 'nix (Determinate Nix 3.21.9) 2.34.8' >"$evidence/version.txt"
  : >"$evidence/version.stderr"
  printf '%s\n' 'nix-installer 3.21.9' >"$evidence/installer-version.txt"
  : >"$evidence/installer-version.stderr"
  chmod 0600 "$evidence/version.txt" "$evidence/version.stderr" \
    "$evidence/installer-version.txt" "$evidence/installer-version.stderr"
  local contract
  contract=$(diene_guest_nix_contract)
  jq -n --argjson guestNix "$contract" '{guestNix:$guestNix}' >"$input"
  case $mode in
    recorded-drift) printf '%s\n' wrong >"$evidence/version.txt" ;;
    non-store)
      install -d -m 0700 "$root/outside/bin"
      cp "$store_bin" "$root/outside/bin/nix"
      rm "$nix_bin"
      ln -s "$root/outside/bin/nix" "$nix_bin"
      ;;
    unresolvable)
      rm "$nix_bin"
      ln -s "$root/missing/bin/nix" "$nix_bin"
      ;;
    installed-copy-mismatch) printf X >>"$installed_copy" ;;
    upload-payload-mismatch) printf X >>"$payload" ;;
    upload-shell-mismatch) printf X >>"$bootstrap" ;;
    installer-version-mismatch) printf '%s\n' 'nix-installer 3.21.8' >"$evidence/installer-version.txt" ;;
    installer-stderr-mismatch) printf '%s\n' warning >"$evidence/installer-version.stderr" ;;
  esac
  export FAKE_IDENTITY_MODE=$mode
  local guest_nix
  guest_nix=$(diene_guest_nix_identity "$input" "$evidence" "$nix_bin" "$store_root" \
    "$installed_copy" "$bootstrap" "$payload" x86_64 "$root")
  jq -n --argjson guestNix "$guest_nix" '{guestNix:$guestNix}' >"$evidence/preflight.json"
  case $mode in
    receipt-mismatch)
      jq '.nixVersion = "tampered"' "$evidence/identity.json" >"$evidence/identity.json.tmp"
      mv "$evidence/identity.json.tmp" "$evidence/identity.json"
      ;;
    binding-digest-mismatch)
      jq '.guestNix.identityReceiptDigest = "sha256:0000000000000000000000000000000000000000000000000000000000000000"' \
        "$evidence/preflight.json" >"$evidence/preflight.json.tmp"
      mv "$evidence/preflight.json.tmp" "$evidence/preflight.json"
      ;;
  esac
  diene_require_guest_nix_preflight_agreement "$evidence/preflight.json" "$evidence/identity.json"
)

guest_nix_identity_refusal() {
  local label=${1:?identity case required} rc=0
  local root=$scratch/guest-nix-identity-$label
  if guest_nix_identity_probe "$label" "$root" >"$root.out" 2>"$root.err"; then
    fail "$label guest Nix identity unexpectedly passed"
  else
    rc=$?
  fi
  [[ $rc == 64 ]] || fail "$label guest Nix identity did not exit 64 (got $rc)"
  assert_contains "$root.err" GuestNixIdentityUnexpected
  [[ ! -e $root/policy.json && ! -e $root/application-mutated ]] ||
    fail "$label guest Nix identity reached a protected mutation"
}

for identity_case in wrong-version empty multiline recorded-drift non-store unresolvable \
  installed-copy-mismatch upload-payload-mismatch upload-shell-mismatch installer-version-mismatch \
  installer-stderr-mismatch receipt-mismatch binding-digest-mismatch; do
  guest_nix_identity_refusal "$identity_case"
done
guest_nix_identity_probe happy "$scratch/guest-nix-identity-happy" \
  >"$scratch/guest-nix-identity-happy.out" 2>"$scratch/guest-nix-identity-happy.err" || {
  sed -n '1,160p' "$scratch/guest-nix-identity-happy.err" >&2
  fail 'the exact direct-path guest Nix identity did not pass'
}

preflight_profile_line=$(rg -n '^diene_source_guest_nix_profile ' \
  "$template_root/scripts/ci/environment-runner-preflight.sh" | cut -d: -f1)
preflight_identity_line=$(rg -n 'guest_nix=\$\(diene_guest_nix_identity' \
  "$template_root/scripts/ci/environment-runner-preflight.sh" | cut -d: -f1)
preflight_node_line=$(rg -n '^nodes=' "$template_root/scripts/ci/environment-runner-preflight.sh" | cut -d: -f1)
driver_preflight_line=$(rg -n 'diene_core_driver_preflight --output' \
  "$template_root/scripts/ci/environment-k3d-run.sh" | cut -d: -f1)
driver_policy_line=$(rg -n 'diene_apply_interim_policy "\$resolved"' \
  "$template_root/scripts/ci/environment-k3d-run.sh" | cut -d: -f1)
# The production application seam is source text, not a regular expression.
# shellcheck disable=SC2016
driver_application_seam='"${DIENE_PLS_BIN:-pls}" env up '
driver_application_line=$(rg -n -F "$driver_application_seam" \
  "$template_root/scripts/ci/environment-k3d-run.sh" | cut -d: -f1)
[[ $preflight_profile_line -lt $preflight_identity_line &&
  $preflight_identity_line -lt $preflight_node_line &&
  $driver_preflight_line -lt $driver_policy_line &&
  $driver_preflight_line -lt $driver_application_line ]] ||
  fail 'guest Nix profile and identity are not ordered before posture, policy, and application mutation'
ok 'exact, empty, multiline, recorded, store-path, installed-copy, upload, receipt, and binding identity cases fail before mutation'

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

probe_adapter_case() (
  local label=${1:?label required}
  cd -- "$work"
  # shellcheck source=/dev/null
  source ./scripts/ci/environment-lib.sh
  diene_validate_inputs
  export DIENE_NSC_CLUSTER_ID="cluster-probe-$label"
  export DIENE_EVIDENCE_STAGING="$scratch/probe-$label-staging"
  install -d -m 0700 "$DIENE_EVIDENCE_STAGING"
  export FAKE_PROBE_LOG="$scratch/probe-$label.log"
  : >"$FAKE_PROBE_LOG"
  diene_preflow_start
  diene_verify_hostile_egress "$scratch/probe-$label.json"
)

expect_probe_refusal() {
  local label=${1:?label required}
  expect_refusal InterimPolicyUnavailable probe_adapter_case "$label"
  [[ ! -e $scratch/probe-$label.json ]] ||
    fail "$label adapter refusal emitted passing hostile-probe evidence"
}

prepare_run 7111
export FAKE_PROBE_FAIL_SCOPE=preexisting-open
expect_probe_refusal preexisting-open-nonzero
unset FAKE_PROBE_FAIL_SCOPE

prepare_run 7112
export FAKE_PROBE_MUTATE_SCOPE=preexisting-open FAKE_PROBE_DROP_ID=preexisting-flow-established
expect_probe_refusal preexisting-open-invalid
unset FAKE_PROBE_MUTATE_SCOPE FAKE_PROBE_DROP_ID

prepare_run 7113
export FAKE_PROBE_FAIL_SCOPE=preexisting-transition
expect_probe_refusal preexisting-transition-nonzero
unset FAKE_PROBE_FAIL_SCOPE

prepare_run 7114
export FAKE_PROBE_MUTATE_SCOPE=preexisting-transition \
  FAKE_PROBE_DROP_ID=preexisting-flow-transition-denial
expect_probe_refusal preexisting-transition-invalid
unset FAKE_PROBE_MUTATE_SCOPE FAKE_PROBE_DROP_ID

prepare_run 7115
export FAKE_PROBE_FAIL_SCOPE=host
expect_probe_refusal host-nonzero
unset FAKE_PROBE_FAIL_SCOPE

prepare_run 7116
export FAKE_PROBE_MUTATE_SCOPE=host FAKE_PROBE_OUTCOME=Fail
expect_probe_refusal host-invalid
unset FAKE_PROBE_MUTATE_SCOPE FAKE_PROBE_OUTCOME

prepare_run 7117
export FAKE_PROBE_FAIL_SCOPE=pod
expect_probe_refusal pod-nonzero
grep -Fq -- '--scope host' "$scratch/probe-pod-nonzero.log" ||
  fail 'host negative probe was skipped before pod failure'
grep -Fq -- '--scope pod' "$scratch/probe-pod-nonzero.log" ||
  fail 'actual-pod failure injection was not exercised'
unset FAKE_PROBE_FAIL_SCOPE

prepare_run 7118
export FAKE_PROBE_MUTATE_SCOPE=pod FAKE_PROBE_DROP_ID=pod-dns-denial
expect_probe_refusal pod-invalid
unset FAKE_PROBE_MUTATE_SCOPE FAKE_PROBE_DROP_ID

prepare_run 7119
export FAKE_PROBE_NO_TRANSCRIPT=host
expect_probe_refusal noop-exit-zero
unset FAKE_PROBE_NO_TRANSCRIPT

prepare_run 7120
export FAKE_PROBE_MUTATE_SCOPE=host FAKE_PROBE_CLUSTER=cluster-foreign
expect_probe_refusal foreign-cluster
unset FAKE_PROBE_MUTATE_SCOPE FAKE_PROBE_CLUSTER

prepare_run 7121
export FAKE_PROBE_MUTATE_SCOPE=pod FAKE_PROBE_REQUIRED=false
expect_probe_refusal optional-observation
unset FAKE_PROBE_MUTATE_SCOPE FAKE_PROBE_REQUIRED

prepare_run 7124
export FAKE_PROBE_MUTATE_SCOPE=preexisting-open FAKE_PROBE_REASON=AdapterObservedDenial
expect_probe_refusal preexisting-open-reason-swap
unset FAKE_PROBE_MUTATE_SCOPE FAKE_PROBE_REASON

prepare_run 7125
export FAKE_PROBE_MUTATE_SCOPE=preexisting-transition \
  FAKE_PROBE_REASON=AdapterObservedFlowEstablished
expect_probe_refusal preexisting-transition-reason-swap
unset FAKE_PROBE_MUTATE_SCOPE FAKE_PROBE_REASON

prepare_run 7126
export FAKE_PROBE_MUTATE_SCOPE=host FAKE_PROBE_REASON=AdapterObservedFlowEstablished
expect_probe_refusal host-reason-swap
unset FAKE_PROBE_MUTATE_SCOPE FAKE_PROBE_REASON

prepare_run 7127
export FAKE_PROBE_MUTATE_SCOPE=pod FAKE_PROBE_REASON=AdapterObservedFlowEstablished
expect_probe_refusal pod-reason-swap
unset FAKE_PROBE_MUTATE_SCOPE FAKE_PROBE_REASON
ok 'nonzero, malformed, reason-swapped, exit-zero no-op, foreign, and optional adapters all refuse'

fallback_tools=$scratch/fallback-tools
fallback_log=$scratch/fallback-tools.log
install -d -m 0700 "$fallback_tools"
: >"$fallback_log"
cat >"$fallback_tools/nc" <<'NC'
#!/usr/bin/env bash
set -euo pipefail
printf 'nc' >>"${FAKE_FALLBACK_LOG:?}"
printf ' %q' "$@" >>"$FAKE_FALLBACK_LOG"
printf '\n' >>"$FAKE_FALLBACK_LOG"
[[ $* == '-w 8 1.1.1.1 80' ]] || exit 127
IFS= read -r _ || true
NC
cat >"$fallback_tools/ss" <<'SS'
#!/usr/bin/env bash
set -euo pipefail
printf 'ss' >>"${FAKE_FALLBACK_LOG:?}"
printf ' %q' "$@" >>"$FAKE_FALLBACK_LOG"
printf '\n' >>"$FAKE_FALLBACK_LOG"
[[ $* == '-Htn state established dst 1.1.1.1:80' ]] || exit 127
printf '%s\n' 'ESTAB 0 0 10.0.0.2:4242 1.1.1.1:80'
SS
cat >"$fallback_tools/curl" <<'CURL'
#!/usr/bin/env bash
set -euo pipefail
printf 'curl' >>"${FAKE_FALLBACK_LOG:?}"
printf ' %q' "$@" >>"$FAKE_FALLBACK_LOG"
printf '\n' >>"$FAKE_FALLBACK_LOG"
case "$*" in
  '-fsS --connect-timeout 1 --max-time 2 http://169.254.169.254/' |
  '-kfsS --connect-timeout 1 --max-time 2 https://1.1.1.1/') exit 22 ;;
  *) exit 127 ;;
esac
CURL
cat >"$fallback_tools/kubectl" <<'KUBECTL_FALLBACK'
#!/usr/bin/env bash
set -euo pipefail
printf 'kubectl' >>"${FAKE_FALLBACK_LOG:?}"
printf ' %q' "$@" >>"$FAKE_FALLBACK_LOG"
printf '\n' >>"$FAKE_FALLBACK_LOG"
case ${1:-} in
  run)
    [[ $# -eq 10 && ${2:-} == diene-egress-* && ${3:-} == --restart=Never &&
      ${4:-} == "--image=${DIENE_EGRESS_CANARY_IMAGE:?}" &&
      ${5:-} == --image-pull-policy=Never && ${6:-} == --command && ${7:-} == -- &&
      ${8:-} == sh && ${9:-} == -ceu ]] || exit 127
    ;;
  wait)
    [[ $# -eq 4 && ${2:-} == "--for=jsonpath={.status.phase}=Succeeded" &&
      ${3:-} == pod/diene-egress-* && ${4:-} == --timeout=30s ]] || exit 127
    ;;
  delete)
    [[ $# -eq 5 && ${2:-} == pod && ${3:-} == diene-egress-* &&
      ${4:-} == --wait=true && ${5:-} == --timeout=30s ]] || exit 127
    ;;
  *) exit 127 ;;
esac
KUBECTL_FALLBACK
chmod 0755 "$fallback_tools/nc" "$fallback_tools/ss" "$fallback_tools/curl" \
  "$fallback_tools/kubectl"

prepare_run 7122
fallback_probes=$scratch/fallback-hostile-probes.json
(
  cd -- "$work"
  # shellcheck source=/dev/null
  source ./scripts/ci/environment-lib.sh
  unset DIENE_EGRESS_PROBE_BIN
  diene_validate_inputs
  export DIENE_NSC_CLUSTER_ID=cluster-fallback-7122
  export DIENE_KUBECTL_BIN="$fallback_tools/kubectl"
  export FAKE_FALLBACK_LOG="$fallback_log"
  export PATH="$fallback_tools:$PATH"
  diene_preflow_start
  diene_verify_hostile_egress "$fallback_probes"
) >"$scratch/fallback-probe.out" 2>"$scratch/fallback-probe.err" || {
  sed -n '1,200p' "$scratch/fallback-probe.err" >&2
  fail 'the built-in hostile egress fallback path failed under controlled seams'
}
jq -e '
  length == 6 and
  ([.[].id] | sort) == ["host-arbitrary-https-denial","host-metadata-denial",
    "pod-arbitrary-https-denial","pod-dns-denial","pod-metadata-denial",
    "preexisting-flow-transition-denial"] and
  all(.[]; .outcome == "Pass" and .required == true) and
  ([.[] | select(.id == "host-metadata-denial" or .id == "host-arbitrary-https-denial")] |
    length == 2 and all(.reasonCode == "ConnectionRefused"))
' "$fallback_probes" >/dev/null ||
  fail 'the built-in fallback did not retain the exact six required Pass observations'
[[ $(grep -c '^curl ' "$fallback_log") == 2 && $(grep -c '^kubectl run ' "$fallback_log") == 1 &&
  $(grep -c '^kubectl wait ' "$fallback_log") == 1 &&
  $(grep -c '^kubectl delete ' "$fallback_log") == 1 ]] ||
  fail 'the built-in fallback did not execute both host and the exact actual-pod negative probes'
ok 'the no-adapter fallback preserves both host observations and all six exact Pass IDs'

prepare_run 7123 ditto-vendor
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

printf '== hermetic direct core/vendor driver dispatch ==\n'

direct_source=$scratch/direct-source
install -d -m 0700 "$direct_source"
cp -R "$work/." "$direct_source/"

cat >"$direct_source/.diene/ci/fake-pls-direct" <<'PLS_DIRECT'
#!/usr/bin/env bash
set -euo pipefail
source_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=/dev/null
source "$source_root/scripts/ci/environment-lib.sh"
printf 'pls %s\n' "$*" >>"${FAKE_DRIVER_EVENT_LOG:?}"
case "${1:-}:${2:-}" in
  closure:import)
    [[ $# -eq 3 && ${3:-} == "${DIENE_CLOSURE_BUNDLE_REF:?}" ]] || exit 127
    ;;
  closure:preflight)
    [[ $# -eq 3 && ${3:-} == --denied-network ]] || exit 127
    ;;
  env:up)
    [[ $# -eq 8 && ${3:-} == --profile && ${5:-} == --build-mode &&
      ${7:-} == --artifact && ${8:-} == "${DIENE_ARTIFACT_DIGEST:?}" ]] || exit 127
    profile=${4:?}
    build_mode=${6:?}
    install -d -m 0700 "${DIENE_RUNTIME_SEARCH_ROOT:?}"
    jq -n --arg profile "$profile" --arg mode "$build_mode" \
      --arg repositoryId "$GITHUB_REPOSITORY_ID" --arg repositoryKey "$GITHUB_REPOSITORY" \
      --arg allocation "$(diene_allocation_key)" --arg generation "$(diene_generation_key)" \
      --arg substrate "direct-${DIENE_LANE}" --arg receipt "$(diene_receipt_id)" \
      --arg artifact "$DIENE_ARTIFACT_DIGEST" '
      {apiVersion:"diene-runtime/v1",profile:$profile,buildMode:$mode,
       owner:{repositoryId:$repositoryId,repositoryKey:$repositoryKey,
         allocationKey:$allocation,generationKey:$generation},
       substrate:{kind:"k3d",name:$substrate,receipt:$receipt},artifact:{digest:$artifact}}
    ' >"$DIENE_RUNTIME_SEARCH_ROOT/runtime.json"
    chmod 0600 "$DIENE_RUNTIME_SEARCH_ROOT/runtime.json"
    ;;
  env:doctor)
    [[ $# -eq 5 && ${3:-} == --profile && ${5:-} == --json ]] || exit 127
    profile=${4:?}
    jq -n --arg profile "$profile" --arg allocation "$(diene_allocation_key)" '
      def leaf($id;$required):
        if $required then {id:$id,outcome:"Pass",required:true,reasonCode:"ControlledUnitInput",
          sourceUid:("unit-"+$id),observedGeneration:1,allocationKey:$allocation,
          transitionTime:"2026-08-01T00:00:00Z"}
        else {id:$id,outcome:"NotRequired",required:false,reasonCode:"NotApplicableToLane"} end;
      {apiVersion:"diene-readiness/v1",profile:$profile,aggregate:"EnvironmentReady",outcome:"Pass",
       readiness:[leaf("SubstrateReady";true),leaf("SeedReady";true),leaf("StoreReady";true),
        leaf("ExternalSecretsReady";true),leaf("DependenciesReady";true),leaf("PVCsReady";true),
        leaf("MigrationsReady";true),leaf("FixturesReady";true),leaf("LogtoReady";true),
        leaf("ArtifactPullReady";true),leaf("ApplicationWorkloadsReady";true),
        leaf("ExposurePrerequisitesReady";true),leaf("ExposureReady";true),
        leaf("EnvironmentReady";true),leaf("AllocationReady";false),
        leaf("CastformProdSafetyReady";false),leaf("CallbackReady";false)]}
    '
    ;;
  env:down)
    [[ $# -eq 4 && ${3:-} == --profile && -f ${DIENE_GARDEN_RUNTIME_FILE:-} ]] || exit 127
    ;;
  *) exit 127 ;;
esac
PLS_DIRECT

cat >"$direct_source/.diene/ci/fake-pull-proof" <<'PULL_DIRECT'
#!/usr/bin/env bash
set -euo pipefail
proof=${1:-}
[[ $# -eq 5 && ${2:-} == --digest && ${3:-} == "${DIENE_ARTIFACT_DIGEST:?}" &&
  ${4:-} == --receipt && ${5:-} == "${DIRECT_RECEIPT_ID:?}" ]] || exit 127
case $proof in
  real-pull | evict-repull | sibling-denial | pull-secret-ownership | credential-removal) ;;
  *) exit 127 ;;
esac
printf 'pull %s\n' "$proof" >>"${FAKE_DRIVER_EVENT_LOG:?}"
PULL_DIRECT

cat >"$direct_source/.diene/ci/fake-closure-verify" <<'CLOSURE_DIRECT'
#!/usr/bin/env bash
set -euo pipefail
case ${1:-} in
  verify)
    [[ $# -eq 9 && ${2:-} == --digest && ${3:-} == "${DIENE_CLOSURE_DIGEST:?}" &&
      ${4:-} == --bundle && ${5:-} == "${DIENE_CLOSURE_BUNDLE_REF:?}" &&
      ${6:-} == --signature-digest && ${7:-} == "${DIENE_CLOSURE_SIGNATURE_BUNDLE_DIGEST:?}" &&
      ${8:-} == --trust-root-digest && ${9:-} == "${DIENE_CLOSURE_TRUST_ROOT_DIGEST:?}" ]] || exit 127
    printf 'closure verify\n' >>"${FAKE_DRIVER_EVENT_LOG:?}"
    ;;
  exact-set)
    [[ $# -eq 4 && ${2:-} == --digest && ${3:-} == "${DIENE_CLOSURE_DIGEST:?}" &&
      ${4:-} == --network-denied ]] || exit 127
    printf 'closure exact-set\n' >>"${FAKE_DRIVER_EVENT_LOG:?}"
    ;;
  *) exit 127 ;;
esac
CLOSURE_DIRECT

cat >"$direct_source/.diene/ci/fake-fleet-negative-observer" <<'FLEET_DIRECT'
#!/usr/bin/env bash
set -euo pipefail
[[ $* == '--fixture bootstrap-fleet-independence-v1 --forbidden diene-fleet-controller --forbidden diene-fleet-agent' ]] ||
  exit 127
printf 'fleet-negative-observed bootstrap-fleet-independence-v1 diene-fleet-controller diene-fleet-agent\n' \
  >>"${FAKE_DRIVER_EVENT_LOG:?}"
FLEET_DIRECT

cat >"$direct_source/.diene/ci/direct-driver-action" <<'ACTION_DIRECT'
#!/usr/bin/env bash
set -euo pipefail
phase=${1:-}
[[ $# -eq 1 ]] || exit 127
case "${DIENE_LANE:?}:$phase" in
  ditto-build-local:setup | ditto-build-local:probe | ditto-build-local:cleanup | \
  ditto-target-pull:setup | ditto-target-pull:probe | ditto-target-pull:cleanup | \
  absol:setup | absol:probe | absol:cleanup | \
  fleet-independence:setup | fleet-independence:probe | fleet-independence:cleanup | \
  ditto-vendor:setup | ditto-vendor:probe | ditto-vendor:cleanup | ditto-vendor:absence) ;;
  *) exit 127 ;;
esac
printf 'journey %s %s\n' "$DIENE_LANE" "$phase" >>"${FAKE_DRIVER_EVENT_LOG:?}"
if [[ $DIENE_LANE == ditto-vendor ]]; then
  [[ -n ${DIENE_VENDOR_CREDENTIAL:-} ]] || exit 65
fi
if [[ $DIENE_LANE == fleet-independence && $phase == probe ]]; then
  fixture=.diene/ci/fixtures/bootstrap-fleet-independence-v1/manifest.yaml
  jq -e '
    .id == "bootstrap-fleet-independence-v1" and
    .forbiddenResources == ["diene-fleet-controller","diene-fleet-agent"]
  ' "$fixture" >/dev/null || exit 66
  .diene/ci/fake-fleet-negative-observer --fixture bootstrap-fleet-independence-v1 \
    --forbidden diene-fleet-controller --forbidden diene-fleet-agent
fi
ACTION_DIRECT

cat >"$direct_source/.diene/ci/direct-broker" <<'BROKER_DIRECT'
#!/usr/bin/env bash
set -euo pipefail
case ${1:-} in
  issue)
    [[ $# -eq 7 && ${2:-} == --action && ${3:-} == demo-vendor &&
      ${4:-} == --output && ${6:-} == --evidence ]] || exit 127
    printf 'broker issue\n' >>"${FAKE_DRIVER_EVENT_LOG:?}"
    printf '%s\n' controlled-unit-credential >"${5:?}"
    chmod 0600 "${5:?}"
    jq -n '{outcome:"Pass",masked:true,issuedAfterReadiness:true}' >"${7:?}"
    ;;
  revoke)
    [[ $# -eq 7 && ${2:-} == --action && ${3:-} == demo-vendor &&
      ${4:-} == --credential-file && ${6:-} == --absence-proven && ${7:-} == true ]] || exit 127
    printf 'broker revoke true\n' >>"${FAKE_DRIVER_EVENT_LOG:?}"
    ;;
  *) exit 127 ;;
esac
BROKER_DIRECT
chmod 0755 "$direct_source/.diene/ci/fake-pls-direct" \
  "$direct_source/.diene/ci/fake-pull-proof" \
  "$direct_source/.diene/ci/fake-closure-verify" \
  "$direct_source/.diene/ci/fake-fleet-negative-observer" \
  "$direct_source/.diene/ci/direct-driver-action" "$direct_source/.diene/ci/direct-broker"
for direct_executable in \
  "$direct_source/.diene/ci/fake-pls-direct" \
  "$direct_source/.diene/ci/fake-pull-proof" \
  "$direct_source/.diene/ci/fake-closure-verify" \
  "$direct_source/.diene/ci/fake-fleet-negative-observer" \
  "$direct_source/.diene/ci/direct-driver-action" \
  "$direct_source/.diene/ci/direct-broker"; do
  bash -n "$direct_executable" || fail "generated direct executable is not valid Bash: $direct_executable"
done
ok 'every generated direct-driver executable is Bash syntax-valid'

direct_fleet_fixture=$direct_source/.diene/ci/fixtures/bootstrap-fleet-independence-v1/manifest.yaml
jq '.forbiddenResources = ["diene-fleet-controller","diene-fleet-agent"]' \
  "$direct_fleet_fixture" >"$direct_fleet_fixture.tmp"
mv "$direct_fleet_fixture.tmp" "$direct_fleet_fixture"
direct_demo_digest="sha256:$(sha256sum "$direct_source/.diene/ci/fixtures/demo/manifest.yaml" | awk '{print $1}')"
direct_fleet_digest="sha256:$(sha256sum "$direct_fleet_fixture" | awk '{print $1}')"
direct_journeys=$direct_source/.diene/ci/journeys.v1.yaml
jq --arg demo "$direct_demo_digest" --arg fleet "$direct_fleet_digest" '
  .journeys |= map(
    .fixturePack.digest = (if .fixturePack.id == "demo" then $demo else $fleet end) |
    .setup = [".diene/ci/direct-driver-action","setup"] |
    .probe = [".diene/ci/direct-driver-action","probe"] |
    .cleanup = [".diene/ci/direct-driver-action","cleanup"])
' "$direct_journeys" >"$direct_journeys.tmp"
mv "$direct_journeys.tmp" "$direct_journeys"
direct_vendors=$direct_source/.diene/ci/vendors.v1.yaml
jq '
  .actions |= map(
    .setup = [".diene/ci/direct-driver-action","setup"] |
    .probe = [".diene/ci/direct-driver-action","probe"] |
    .cleanup = [".diene/ci/direct-driver-action","cleanup"] |
    .absence = [".diene/ci/direct-driver-action","absence"])
' "$direct_vendors" >"$direct_vendors.tmp"
mv "$direct_vendors.tmp" "$direct_vendors"
if rg -n '/bin/true' "$direct_journeys" "$direct_vendors" >"$scratch/direct-noop-actions"; then
  sed -n '1,120p' "$scratch/direct-noop-actions" >&2
  fail 'a direct-driver journey or vendor action still uses /bin/true'
fi

direct_fake_preflight() {
  local output=
  while (($#)); do
    case $1 in
      --output) output=${2:-}; shift 2 ;;
      *) return 127 ;;
    esac
  done
  [[ -n $output ]] || return 127
  printf 'preflight %s\n' "$DIENE_LANE" >>"${FAKE_DRIVER_EVENT_LOG:?}"
  # Even this controlled unit stub may not invent a runtime version or service
  # range; both come from the admitted inputs under test.
  jq -n --arg cluster "$DIENE_NSC_CLUSTER_ID" --arg k3s "${DIENE_ADMITTED_K3S_VERSION:?}" \
    --arg serviceCidr "${DIENE_K3S_SERVICE_CIDR:?}" '
    {outcome:"Pass",reasonCode:"NamespaceWolfiBuiltInK3sReady",clusterId:$cluster,
     identitySource:"controlled-direct-driver-unit-input",os:{id:"wolfi",version:"rolling",uid:0},
     k3s:{version:$k3s,kubernetesVersion:$k3s,nodeCount:1,
       capacity:{cpu:"16",memory:"32Gi"}},
     network:{podCidrs:["10.142.0.0/16","fd00:142::/64"],serviceCidrs:[$serviceCidr],
       ipv6Disabled:false,namespaceIngress:false,publicBinding:false},
     storage:{defaultClass:"local-path"},
     policyBackend:{mechanism:"iptables",backend:"nf_tables",version:"iptables v1.8.13 (nf_tables)"},
     cacheAttached:false,platformStatus:"platform per-instance policy pending (support ask #4)"}
  ' >"$output"
}

prepare_direct_driver_case() {
  local run_id=${1:?run id required} lane=${2:?lane required}
  local direct_runner=$scratch/direct-runner-$run_id
  prepare_run "$run_id" "$lane" "$direct_runner" "$scratch/direct-unused-nsc-$run_id"
  DIRECT_STATE=$scratch/direct-state-$run_id
  DIRECT_EVENT_LOG=$DIRECT_STATE/events.log
  DIRECT_TABLE_STATE=$DIRECT_STATE/policy-state
  install -d -m 0700 "$DIRECT_STATE/receipts" "$DIRECT_STATE/runtime-search" \
    "$DIRECT_STATE/tmp" "$DIRECT_TABLE_STATE"
  cp "$DIENE_ARTIFACT_SUBJECT" "$DIRECT_STATE/artifact-subject.json"
  chmod 0600 "$DIRECT_STATE/artifact-subject.json"
  export DIENE_ARTIFACT_SUBJECT="$DIRECT_STATE/artifact-subject.json"
  export RUNNER_TEMP="$DIRECT_STATE/tmp" DIENE_SCHEMA_DIR="$direct_source/schemas/ci"
  export DIENE_NSC_CLUSTER_ID="direct-$lane-$run_id" DIENE_NSC_VERSION=v0.0.532
  export DIENE_NSC_ARTIFACT_DIGEST=sha256:6666666666666666666666666666666666666666666666666666666666666666
  export DIENE_NSC_BINARY_DIGEST="$fake_nsc_binary_digest"
  DIENE_SOURCE_ARCHIVE_DIGEST="sha256:$(sha256sum "$source_archive" | awk '{print $1}')"
  export DIENE_SOURCE_ARCHIVE_DIGEST
  export DIENE_CACHE_ATTACHED=false DIENE_ORCHESTRATOR_VENUE=local
  export DIENE_ORCHESTRATOR_LABEL=local-contract-test
  export DIENE_ORCHESTRATOR_FALLBACK_REASON=''
  export DIENE_EGRESS_CONTRACT="$DIRECT_STATE/egress-contract.json"
  export DIENE_PLS_BIN=.diene/ci/fake-pls-direct
  export DIENE_PULL_PROOF_BIN=.diene/ci/fake-pull-proof
  export DIENE_CLOSURE_VERIFY_BIN=.diene/ci/fake-closure-verify
  export DIENE_RUNTIME_SEARCH_ROOT="$DIRECT_STATE/runtime-search"
  export DIENE_RECEIPT_DIR="$DIRECT_STATE/receipts"
  export DIENE_KUBECTL_BIN="$policy_tools/kubectl"
  export DIENE_IPTABLES_BIN="$policy_tools/iptables4"
  export DIENE_IP6TABLES_BIN="$policy_tools/iptables6"
  export DIENE_EGRESS_RESOLVER_BIN="$policy_tools/resolver"
  export DIENE_IPV6_DISABLE_PATH="$ipv6_enabled_path"
  export FAKE_DRIVER_EVENT_LOG="$DIRECT_EVENT_LOG"
  export FAKE_TABLE_STATE="$DIRECT_TABLE_STATE" FAKE_TABLE_LOG="$DIRECT_STATE/tables.log"
  export FAKE_KUBECTL_LOG="$DIRECT_STATE/kubectl.log"
  export FAKE_L7_LOG="$DIRECT_STATE/l7.log" FAKE_PROBE_LOG="$DIRECT_STATE/probe.log"
  export SSH_CONNECTION='192.0.2.10 4242 10.0.0.2 22'
  : >"$DIRECT_EVENT_LOG"
  : >"$FAKE_TABLE_LOG"
  : >"$FAKE_KUBECTL_LOG"
  : >"$FAKE_L7_LOG"
  : >"$FAKE_PROBE_LOG"
  if [[ $lane == ditto-vendor ]]; then
    export DIENE_VENDOR_CREDENTIAL_BROKER_BIN=.diene/ci/direct-broker
  fi
  (
    cd -- "$direct_source"
    # shellcheck source=/dev/null
    source ./scripts/ci/environment-lib.sh
    diene_prepare_egress_contract "$DIENE_EGRESS_CONTRACT"
  )
  DIRECT_RECEIPT_ID=$(
    cd -- "$direct_source"
    # shellcheck source=/dev/null
    source ./scripts/ci/environment-lib.sh
    diene_receipt_id
  )
  export DIRECT_RECEIPT_ID
  local create_digest armed_receipt
  create_digest="sha256:$(printf '%s' "$DIENE_NSC_CLUSTER_ID|controlled-create" | sha256sum | awk '{print $1}')"
  armed_receipt=$(
    cd -- "$direct_source"
    # shellcheck source=/dev/null
    source ./scripts/ci/environment-lib.sh
    diene_arm_receipt "$DIRECT_RECEIPT_ID" "$DIENE_NSC_CLUSTER_ID" "$create_digest" 0 false \
      "$DIENE_NSC_VERSION" "$DIENE_NSC_ARTIFACT_DIGEST" "$DIENE_NSC_BINARY_DIGEST"
  )
  mv "$armed_receipt" "$DIRECT_STATE/receipts/exact.json"
  export DIRECT_STATE DIRECT_EVENT_LOG DIRECT_TABLE_STATE
}

run_direct_core_case() (
  cd -- "$direct_source"
  # shellcheck source=/dev/null
  source ./scripts/ci/environment-k3d-run.sh
  # The sourced driver calls both overrides indirectly.
  # shellcheck disable=SC2329
  diene_load_remote_inputs() {
    [[ ${1:-} == "$DIRECT_STATE" ]] || diene_die InputContractInvalid 'unit state mismatch'
  }
  # shellcheck disable=SC2329
  diene_core_driver_preflight() {
    direct_fake_preflight "$@"
  }
  driver_core "$DIRECT_STATE"
)

run_direct_vendor_case() (
  cd -- "$direct_source"
  # shellcheck source=/dev/null
  source ./scripts/ci/environment-vendor-run.sh
  # The sourced driver calls both overrides indirectly.
  # shellcheck disable=SC2329
  diene_load_remote_inputs() {
    [[ ${1:-} == "$DIRECT_STATE" ]] || diene_die InputContractInvalid 'unit state mismatch'
  }
  # shellcheck disable=SC2329
  diene_vendor_driver_preflight() {
    direct_fake_preflight "$@"
  }
  vendor_driver_core "$DIRECT_STATE"
)

assert_direct_vendor_main_no_return_trap() (
  cd -- "$direct_source"
  # shellcheck source=/dev/null
  source ./scripts/ci/environment-vendor-run.sh
  environment_vendor_main --validate-inputs
  [[ -z $(trap -p RETURN) ]]
)

assert_direct_success() {
  local lane=${1:?lane required} kind=${2:-core}
  local report=$DIRECT_STATE/evidence/core-report.driver.json
  local schema=diene-environment-report-v1.schema.json
  local completed_reason=DriverCompleted
  [[ $kind != vendor ]] || {
    report=$DIRECT_STATE/evidence/vendor-report.driver.json
    schema=diene-vendor-report-v1.schema.json
    completed_reason=VendorCompleted
  }
  jq -e --arg reason "$completed_reason" \
    '.outcome == "Pass" and .reasonCode == $reason and .exitCode == 0' \
    "$DIRECT_STATE/evidence/driver-status.json" >/dev/null ||
    fail "$lane direct driver did not package a green status"
  local finalized_report=$DIRECT_STATE/final-$kind-report.json
  (
    cd -- "$direct_source"
    DIENE_EVIDENCE_STAGING="$DIRECT_STATE/evidence/staging" \
      DIENE_PROOF_BUNDLE_DIR="$DIRECT_STATE/evidence" \
      ./scripts/ci/environment-report.sh --kind "$kind" --input "$report" \
      --output "$finalized_report"
  ) || fail "$lane direct driver report did not pass real leakage finalisation"
  report=$finalized_report
  local schema_log=$DIRECT_STATE/report-schema-validation.log
  if ! "${DIENE_SCHEMA_VALIDATOR_BIN:-check-jsonschema}" \
    --base-uri "file://$direct_source/schemas/ci/" \
    --schemafile "$direct_source/schemas/ci/$schema" "$report" >"$schema_log" 2>&1; then
    sed -n '1,240p' "$report" >&2
    sed -n '1,240p' "$schema_log" >&2
    fail "$lane direct driver report is not schema-valid"
  fi
  jq -e '.namespace.policy.applied == true and .namespace.policy.hostileProbes == "Pass" and
    .cleanup == {outcome:"Pass",reasonCode:"ExactReceiptDestroyed",debt:[]}' \
    "$DIRECT_STATE/evidence/ci-receipt.json" >/dev/null ||
    fail "$lane direct driver did not bind policy and exact cleanup into its receipt"
  assert_policy_state_absent "$DIRECT_TABLE_STATE" "$lane-direct-driver"
}

assert_direct_events() {
  local lane=${1:?lane required} expected=${2:?expected events required}
  [[ $(<"$DIRECT_EVENT_LOG") == "$expected" ]] || {
    sed -n '1,200p' "$DIRECT_EVENT_LOG" >&2
    fail "$lane direct driver dispatch/order changed"
  }
}

# These are controlled unit inputs to the real driver consumers. They do not
# claim Garden product readiness or production endpoint/resource coverage.
prepare_direct_driver_case 7201 ditto-build-local
run_direct_core_case >"$scratch/direct-build-local.out" 2>"$scratch/direct-build-local.err" || {
  sed -n '1,240p' "$scratch/direct-build-local.err" >&2
  sed -n '1,240p' "$DIRECT_EVENT_LOG" >&2
  sed -n '1,240p' "$DIRECT_STATE/evidence/staging/stderr" >&2
  fail 'the real build-local driver_core unit dispatch failed'
}
assert_direct_success ditto-build-local
expected_direct_events=$'preflight ditto-build-local\n'
expected_direct_events+="pls env up --profile ditto --build-mode build-local --artifact $ARTIFACT_DIGEST"$'\n'
expected_direct_events+=$'pls env doctor --profile ditto --json\n'
expected_direct_events+=$'journey ditto-build-local setup\njourney ditto-build-local probe\njourney ditto-build-local cleanup\n'
expected_direct_events+='pls env down --profile ditto'
assert_direct_events ditto-build-local "$expected_direct_events"

prepare_direct_driver_case 7202 ditto-target-pull
run_direct_core_case >"$scratch/direct-target-pull.out" 2>"$scratch/direct-target-pull.err" || {
  sed -n '1,240p' "$scratch/direct-target-pull.err" >&2
  fail 'the real target-pull driver_core unit dispatch failed'
}
assert_direct_success ditto-target-pull
expected_direct_events=$'preflight ditto-target-pull\n'
expected_direct_events+="pls env up --profile ditto --build-mode target-pull --artifact $ARTIFACT_DIGEST"$'\n'
expected_direct_events+=$'pls env doctor --profile ditto --json\n'
expected_direct_events+=$'pull real-pull\npull evict-repull\npull sibling-denial\npull pull-secret-ownership\npull credential-removal\n'
expected_direct_events+=$'journey ditto-target-pull setup\njourney ditto-target-pull probe\njourney ditto-target-pull cleanup\n'
expected_direct_events+='pls env down --profile ditto'
assert_direct_events ditto-target-pull "$expected_direct_events"

prepare_direct_driver_case 7203 absol
run_direct_core_case >"$scratch/direct-absol.out" 2>"$scratch/direct-absol.err" || {
  sed -n '1,240p' "$scratch/direct-absol.err" >&2
  fail 'the real Absol driver_core unit dispatch failed'
}
assert_direct_success absol
expected_direct_events=$'preflight absol\nclosure verify\n'
expected_direct_events+="pls closure import oci://ghcr.io/atomicloud/example/closure/$SOURCE_SHA"$'\n'
expected_direct_events+=$'pls closure preflight --denied-network\nclosure exact-set\n'
expected_direct_events+="pls env up --profile absol --build-mode build-local --artifact $ARTIFACT_DIGEST"$'\n'
expected_direct_events+=$'pls env doctor --profile absol --json\n'
expected_direct_events+=$'journey absol setup\njourney absol probe\njourney absol cleanup\n'
expected_direct_events+='pls env down --profile absol'
assert_direct_events absol "$expected_direct_events"

prepare_direct_driver_case 7204 fleet-independence
run_direct_core_case >"$scratch/direct-fleet.out" 2>"$scratch/direct-fleet.err" || {
  sed -n '1,240p' "$scratch/direct-fleet.err" >&2
  fail 'the real fleet-independence driver_core unit dispatch failed'
}
assert_direct_success fleet-independence
if ! jq -e '
  .coverage == [{id:"fleet-endpoint-resource-negative-probe",outcome:"Unavailable",
    reasonCode:"FleetEndpointResourceNegativeProbeContractUnavailable",required:false}] and
  (.journeys | length) == 1 and
  (.journeys[0] as $journey |
    ($journey | keys | sort) ==
      ["durationSeconds","fixturePackDigest","id","outcome","reasonCode","required"] and
    $journey.id == "fleet-demo" and $journey.outcome == "Pass" and
    $journey.reasonCode == "AssertionsSatisfied" and $journey.required == true and
    ($journey.durationSeconds | type == "number" and . >= 0) and
    ($journey.fixturePackDigest | test("^sha256:[0-9a-f]{64}$")))
' "$DIRECT_STATE/final-core-report.json" >/dev/null; then
  sed -n '1,240p' "$DIRECT_STATE/final-core-report.json" >&2
  fail 'fleet direct unit dispatch claimed production proof or lost the explicit Unavailable row'
fi
expected_direct_events=$'preflight fleet-independence\n'
expected_direct_events+="pls env up --profile ditto --build-mode build-local --artifact $ARTIFACT_DIGEST"$'\n'
expected_direct_events+=$'pls env doctor --profile ditto --json\n'
expected_direct_events+=$'journey fleet-independence setup\njourney fleet-independence probe\n'
expected_direct_events+=$'fleet-negative-observed bootstrap-fleet-independence-v1 diene-fleet-controller diene-fleet-agent\n'
expected_direct_events+=$'journey fleet-independence cleanup\n'
expected_direct_events+='pls env down --profile ditto'
assert_direct_events fleet-independence "$expected_direct_events"

prepare_direct_driver_case 7205 ditto-vendor
assert_direct_vendor_main_no_return_trap ||
  fail 'sourced environment_vendor_main leaked a RETURN cleanup trap'
run_direct_vendor_case >"$scratch/direct-vendor.out" 2>"$scratch/direct-vendor.err" || {
  sed -n '1,240p' "$scratch/direct-vendor.err" >&2
  fail 'the real vendor_driver_core unit dispatch failed'
}
assert_direct_success ditto-vendor vendor
expected_direct_events=$'preflight ditto-vendor\n'
expected_direct_events+="pls env up --profile ditto --build-mode build-local --artifact $ARTIFACT_DIGEST"$'\n'
expected_direct_events+=$'pls env doctor --profile ditto --json\nbroker issue\n'
expected_direct_events+=$'journey ditto-vendor setup\njourney ditto-vendor probe\n'
expected_direct_events+=$'journey ditto-vendor cleanup\njourney ditto-vendor absence\nbroker revoke true\n'
expected_direct_events+='pls env down --profile ditto'
assert_direct_events ditto-vendor "$expected_direct_events"
ok 'real sourced drivers dispatch build-local, five pull proofs, Absol closure order, fleet observable, and vendor cleanup without product-readiness claims'

printf '== report namespaces and additive schema compatibility ==\n'

validate_report_namespace_case() (
  cd -- "$work"
  # shellcheck source=/dev/null
  source ./scripts/ci/environment-lib.sh
  diene_validate_report_namespace "$@"
)

validate_report_namespace_case ditto-build-local "$ARTIFACT_DIGEST" ''
validate_report_namespace_case ditto-vendor '' "$ARTIFACT_DIGEST"
ok 'the exact core and vendor digest namespaces are accepted only by their owning lanes'

expect_refusal ReportNamespaceViolation validate_report_namespace_case ditto-build-local '' ''
expect_refusal ReportNamespaceViolation validate_report_namespace_case ditto-build-local \
  "$ARTIFACT_DIGEST" "$ARTIFACT_DIGEST"
expect_refusal ReportNamespaceViolation validate_report_namespace_case ditto-build-local '' "$ARTIFACT_DIGEST"
expect_refusal ReportNamespaceViolation validate_report_namespace_case ditto-vendor '' ''
expect_refusal ReportNamespaceViolation validate_report_namespace_case ditto-vendor \
  "$ARTIFACT_DIGEST" "$ARTIFACT_DIGEST"
expect_refusal ReportNamespaceViolation validate_report_namespace_case ditto-vendor "$ARTIFACT_DIGEST" ''

core_with_vendor=$scratch/core-with-vendor.json
vendor_with_core=$scratch/vendor-with-core.json
jq '.vendorOutcome = {id:"foreign",outcome:"Pass",reasonCode:"Foreign",required:false,durationSeconds:0}' \
  "$happy_core_report" >"$core_with_vendor"
jq '.journeys = []' "$happy_vendor_report" >"$vendor_with_core"
expect_refusal ReportNamespaceViolation "$work/scripts/ci/environment-report.sh" \
  --kind core --input "$happy_vendor_report" --output "$scratch/vendor-as-core.json"
expect_refusal ReportNamespaceViolation "$work/scripts/ci/environment-report.sh" \
  --kind vendor --input "$happy_core_report" --output "$scratch/core-as-vendor.json"
expect_refusal ReportNamespaceViolation "$work/scripts/ci/environment-report.sh" \
  --kind core --input "$core_with_vendor" --output "$scratch/core-cross-field.json"
expect_refusal ReportNamespaceViolation "$work/scripts/ci/environment-report.sh" \
  --kind vendor --input "$vendor_with_core" --output "$scratch/vendor-cross-field.json"

legacy_core=$scratch/legacy-core-report.json
legacy_vendor=$scratch/legacy-vendor-report.json
legacy_runtime=$scratch/legacy-garden-runtime.json
jq '
  del(.namespaceLifecycle,.checkpointChain,
      .instance.clusterId,.instance.osId,.instance.osVersion,.instance.k3sVersion,
      .instance.kubernetesVersion,.instance.nodeCount,.instance.capacity,
      .tooling.nscVersion,.tooling.nscArtifactDigest,.tooling.nscBinaryDigest,
      .tooling.sourceArchiveDigest,.tooling.artifactSubjectDigest,
      .evidence.proofBundle,
      .evidence.egressCanary.profileId,.evidence.egressCanary.enforcement,
      .evidence.egressCanary.platformStatus,.evidence.egressCanary.hostileProbes,
      .timings.createToKubernetesReadySeconds,.timings.driverTransferSetupSeconds,
      .timings.renderApplySeconds,.timings.collectionSeconds,.timings.destroySeconds,
      .timings.totalColdSeconds)
' "$happy_core_report" >"$legacy_core"
jq '
  del(.namespaceLifecycle,.checkpointChain,
      .instance.clusterId,.instance.osId,.instance.osVersion,.instance.k3sVersion,
      .instance.kubernetesVersion,.instance.nodeCount,.instance.capacity,
      .tooling.nscVersion,.tooling.nscArtifactDigest,.tooling.nscBinaryDigest,
      .tooling.sourceArchiveDigest,.tooling.artifactSubjectDigest,
      .evidence.proofBundle,
      .evidence.egressCanary.profileId,.evidence.egressCanary.enforcement,
      .evidence.egressCanary.platformStatus,.evidence.egressCanary.hostileProbes,
      .timings.createToKubernetesReadySeconds,.timings.driverTransferSetupSeconds,
      .timings.renderApplySeconds,.timings.collectionSeconds,.timings.destroySeconds,
      .timings.totalColdSeconds) |
  .credential.issuer = "host-owned-broker"
' "$happy_vendor_report" >"$legacy_vendor"
jq -n --arg digest "$ARTIFACT_DIGEST" '
  {apiVersion:"diene-runtime/v1",profile:"ditto",buildMode:"build-local",
   owner:{repositoryId:"12345",repositoryKey:"AtomiCloud/example",
     allocationKey:"legacy-allocation",generationKey:"legacy-generation",gardenOwnedField:"retained"},
   substrate:{kind:"k3d",name:"opaque-compatibility-name",receipt:"legacy-receipt",
     kubeconfig:"/run/legacy/kubeconfig",context:"legacy-context",gardenOwnedField:true},
   artifact:{digest:$digest,gardenOwnedField:"retained"},gardenOwnedTopLevel:{retained:true}}
' >"$legacy_runtime"

validator=${DIENE_SCHEMA_VALIDATOR_BIN:-check-jsonschema}
schema_dir=$work/schemas/ci
"$validator" --base-uri "file://$schema_dir/" \
  --schemafile "$schema_dir/diene-environment-report-v1.schema.json" "$legacy_core" >/dev/null ||
  fail 'the additive Namespace schema rejected a previously valid core report'
"$validator" --base-uri "file://$schema_dir/" \
  --schemafile "$schema_dir/diene-vendor-report-v1.schema.json" "$legacy_vendor" >/dev/null ||
  fail 'the additive Namespace schema rejected a previously valid vendor report'
"$validator" --base-uri "file://$schema_dir/" \
  --schemafile "$schema_dir/diene-runtime-consumption-v1.schema.json" "$legacy_runtime" >/dev/null ||
  fail 'the Garden consumption view required CI-owned Namespace fields'
ok 'legacy core/vendor reports and the Garden-owned runtime view remain backward compatible'

cached_report_case=$scratch/cached-ditto-report
cached_report_input=$cached_report_case/input.json
cached_report_output=$cached_report_case/output.json
install -d -m 0700 "$cached_report_case/staging" "$cached_report_case/proof" \
  "$cached_report_case/runner"
for required_surface in stdout stderr argv environ; do
  : >"$cached_report_case/staging/$required_surface"
done
: >"$cached_report_case/github-output"
: >"$cached_report_case/github-env"
: >"$cached_report_case/summary"
jq '
  .namespaceLifecycle.cacheAttached = true |
  .namespaceLifecycle.orchestratorLabel = "nscloud-ubuntu-26.04-amd64-16x32-with-cache"
' "$happy_core_report" >"$cached_report_input"
env DIENE_ORCHESTRATOR_LABEL=nscloud-ubuntu-26.04-amd64-16x32-with-cache \
  DIENE_LEAK_CANARY=cached-ditto-report-canary \
  DIENE_EVIDENCE_STAGING="$cached_report_case/staging" \
  DIENE_PROOF_BUNDLE_DIR="$cached_report_case/proof" DIENE_SCHEMA_DIR="$schema_dir" \
  RUNNER_TEMP="$cached_report_case/runner" GITHUB_OUTPUT="$cached_report_case/github-output" \
  GITHUB_ENV="$cached_report_case/github-env" GITHUB_STEP_SUMMARY="$cached_report_case/summary" \
  "$work/scripts/ci/environment-report.sh" --kind core --input "$cached_report_input" \
  --output "$cached_report_output" >"$cached_report_case/stdout" 2>"$cached_report_case/stderr" || {
  sed -n '1,160p' "$cached_report_case/stderr" >&2
  fail 'the real report finalizer rejected the cached Ditto 26.04 label'
}
jq -e '
  .namespaceLifecycle.cacheAttached == true and
  .namespaceLifecycle.orchestratorLabel ==
    "nscloud-ubuntu-26.04-amd64-16x32-with-cache" and
  .evidence.leakageScan.outcome == "Pass"
' "$cached_report_output" >/dev/null ||
  fail 'the finalized cached Ditto report lost its cache/label/leakage facts'
ok 'a cached Ditto 26.04 report passes the real closed report finalizer and schema'

printf '== every leakage encoding is suppressed on every evidence surface ==\n'

jq -e '
  .evidence.leakageScan.outcome == "Pass" and
  .evidence.leakageScan.encodings ==
    ["raw","base64","url-encoded","json-escaped","newline-normalized","kubeconfig-embedded"] and
  (.evidence.leakageScan.scannedPaths | length) >= 3
' "$happy_core_report" >/dev/null || fail 'the clean lifecycle did not record the complete leakage scan vocabulary'
ok 'a clean outer proof records all six leakage encodings and scanned surfaces'

leak_interface=$scratch/leak-interface
install -d -m 0700 "$leak_interface/staging" "$leak_interface/proof" "$leak_interface/runner"
for required_surface in stdout stderr argv environ; do : >"$leak_interface/staging/$required_surface"; done
: >"$leak_interface/github-output"
: >"$leak_interface/github-env"
: >"$leak_interface/summary"
expect_refusal EvidenceLeakDetected env -u DIENE_LEAK_CANARY \
  DIENE_EVIDENCE_STAGING="$leak_interface/staging" DIENE_PROOF_BUNDLE_DIR="$leak_interface/proof" \
  DIENE_SCHEMA_DIR="$schema_dir" RUNNER_TEMP="$leak_interface/runner" \
  GITHUB_OUTPUT="$leak_interface/github-output" GITHUB_ENV="$leak_interface/github-env" \
  GITHUB_STEP_SUMMARY="$leak_interface/summary" "$work/scripts/ci/environment-report.sh" \
  --kind core --input "$happy_core_report" --output "$leak_interface/no-canary.json"
rm -f -- "$leak_interface/staging/stderr"
expect_refusal EvidenceLeakageInterfaceUnavailable env DIENE_LEAK_CANARY=interface-canary \
  DIENE_EVIDENCE_STAGING="$leak_interface/staging" DIENE_PROOF_BUNDLE_DIR="$leak_interface/proof" \
  DIENE_SCHEMA_DIR="$schema_dir" RUNNER_TEMP="$leak_interface/runner" \
  GITHUB_OUTPUT="$leak_interface/github-output" GITHUB_ENV="$leak_interface/github-env" \
  GITHUB_STEP_SUMMARY="$leak_interface/summary" "$work/scripts/ci/environment-report.sh" \
  --kind core --input "$happy_core_report" --output "$leak_interface/missing-surface.json"

: >"$leak_interface/staging/stderr"
mkfifo "$leak_interface/proof/hostile-fifo"
printf '%s\n' stale-report-sentinel >"$leak_interface/special-surface.json"
expect_refusal EvidenceLeakageInterfaceUnavailable env DIENE_LEAK_CANARY=interface-canary \
  DIENE_EVIDENCE_STAGING="$leak_interface/staging" DIENE_PROOF_BUNDLE_DIR="$leak_interface/proof" \
  DIENE_SCHEMA_DIR="$schema_dir" RUNNER_TEMP="$leak_interface/runner" \
  GITHUB_OUTPUT="$leak_interface/github-output" GITHUB_ENV="$leak_interface/github-env" \
  GITHUB_STEP_SUMMARY="$leak_interface/summary" "$work/scripts/ci/environment-report.sh" \
  --kind core --input "$happy_core_report" --output "$leak_interface/special-surface.json"
[[ ! -e $leak_interface/special-surface.json ]] ||
  fail 'a special evidence surface left a stale report artifact'
rm -f -- "$leak_interface/proof/hostile-fifo"

printf '%s\n' unreadable >"$leak_interface/proof/unreadable"
chmod 000 "$leak_interface/proof/unreadable"
expect_refusal EvidenceLeakageInterfaceUnavailable env DIENE_LEAK_CANARY=interface-canary \
  DIENE_EVIDENCE_STAGING="$leak_interface/staging" DIENE_PROOF_BUNDLE_DIR="$leak_interface/proof" \
  DIENE_SCHEMA_DIR="$schema_dir" RUNNER_TEMP="$leak_interface/runner" \
  GITHUB_OUTPUT="$leak_interface/github-output" GITHUB_ENV="$leak_interface/github-env" \
  GITHUB_STEP_SUMMARY="$leak_interface/summary" "$work/scripts/ci/environment-report.sh" \
  --kind core --input "$happy_core_report" --output "$leak_interface/unreadable-surface.json"
chmod 0600 "$leak_interface/proof/unreadable"
rm -f -- "$leak_interface/proof/unreadable"

printf '%s\n' stale-report-sentinel >"$leak_interface/grep-error.json"
expect_refusal EvidenceLeakageInterfaceUnavailable env DIENE_LEAK_CANARY=interface-canary \
  DIENE_GREP_BIN="$fake_grep_error" DIENE_EVIDENCE_STAGING="$leak_interface/staging" \
  DIENE_PROOF_BUNDLE_DIR="$leak_interface/proof" DIENE_SCHEMA_DIR="$schema_dir" \
  RUNNER_TEMP="$leak_interface/runner" GITHUB_OUTPUT="$leak_interface/github-output" \
  GITHUB_ENV="$leak_interface/github-env" GITHUB_STEP_SUMMARY="$leak_interface/summary" \
  "$work/scripts/ci/environment-report.sh" --kind core --input "$happy_core_report" \
  --output "$leak_interface/grep-error.json"
[[ ! -e $leak_interface/grep-error.json ]] || fail 'grep status 2 left a stale report artifact'
ok 'special, unreadable, and grep-error surfaces all fail closed without an output artifact'

leak_canary=$'line one/+"?&\nline two'
leak_base64=$(printf '%s' "$leak_canary" | base64 | tr -d '\n')
leak_url=$(jq -rn --arg value "$leak_canary" '$value | @uri')
leak_json=$(jq -rn --arg value "$leak_canary" '$value | tojson | .[1:-1]')
leak_newline=$(printf '%s' "$leak_canary" | tr '\n' ' ')
leak_kubeconfig=$(printf '%s' "$leak_base64" | base64 | tr -d '\n')
leak_encoding_names=(raw base64 url-encoded json-escaped newline-normalized kubeconfig-embedded)
leak_encoding_values=("$leak_canary" "$leak_base64" "$leak_url" "$leak_json" "$leak_newline" "$leak_kubeconfig")
leak_surfaces=(argv stdout stderr environ garden-json workspace runner-temp github-env github-output summary cache candidate-artifact)
leak_cases=0
for leak_surface in "${leak_surfaces[@]}"; do
  for leak_index in "${!leak_encoding_names[@]}"; do
    leak_encoding=${leak_encoding_names[$leak_index]}
    leak_value=${leak_encoding_values[$leak_index]}
    leak_case=$scratch/leak-matrix/$leak_surface/$leak_encoding
    leak_staging=$leak_case/staging
    leak_proof=$leak_case/proof
    leak_runner=$leak_case/runner
    leak_workspace=$leak_case/workspace
    leak_cache=$leak_case/cache
    install -d -m 0700 "$leak_staging" "$leak_proof" "$leak_runner/extra" \
      "$leak_workspace" "$leak_cache"
    for required_surface in stdout stderr argv environ; do : >"$leak_staging/$required_surface"; done
    leak_output_file=$leak_case/github-output
    leak_env_file=$leak_case/github-env
    leak_summary_file=$leak_case/summary
    : >"$leak_output_file"
    : >"$leak_env_file"
    : >"$leak_summary_file"
    case $leak_surface in
      argv | stdout | stderr | environ) leak_target=$leak_staging/$leak_surface ;;
      garden-json) leak_target=$leak_proof/garden-command.json ;;
      workspace) leak_target=$leak_workspace/leak.txt ;;
      runner-temp) leak_target=$leak_runner/extra/leak.txt ;;
      github-env) leak_target=$leak_env_file ;;
      github-output) leak_target=$leak_output_file ;;
      summary) leak_target=$leak_summary_file ;;
      cache) leak_target=$leak_cache/leak.txt ;;
      candidate-artifact) leak_target=$leak_proof/candidate-artifact.tar ;;
      *) fail "unknown leakage test surface $leak_surface" ;;
    esac
    printf '%s' "$leak_value" >"$leak_target"
    if DIENE_LEAK_CANARY="$leak_canary" DIENE_EVIDENCE_STAGING="$leak_staging" \
      DIENE_PROOF_BUNDLE_DIR="$leak_proof" DIENE_SCHEMA_DIR="$schema_dir" RUNNER_TEMP="$leak_runner" \
      GITHUB_WORKSPACE="$leak_workspace" GITHUB_OUTPUT="$leak_output_file" GITHUB_ENV="$leak_env_file" \
      GITHUB_STEP_SUMMARY="$leak_summary_file" DIENE_CACHE_DIR="$leak_cache" \
      "$work/scripts/ci/environment-report.sh" --kind core --input "$happy_core_report" \
        --output "$leak_case/published.json" >"$leak_case/out" 2>"$leak_case/err"; then
      fail "$leak_encoding leakage on $leak_surface was published"
    fi
    grep -Fq EvidenceLeakDetected "$leak_case/err" || {
      sed -n '1,120p' "$leak_case/err" >&2
      fail "$leak_encoding leakage on $leak_surface lost its stable refusal"
    }
    [[ ! -e $leak_case/published.json ]] || fail "$leak_encoding leakage left a candidate report"
    leak_cases=$((leak_cases + 1))
  done
  ok "all six leakage encodings are suppressed on $leak_surface"
done
[[ $leak_cases == 72 ]] || fail 'the complete six-by-twelve leakage matrix did not execute'

printf '== archive membership consumes tar output without SIGPIPE ==\n'

require_source_members_case() (
  # shellcheck source=/dev/null
  source "$work/scripts/ci/environment-lib.sh"
  diene_require_archive_members "$@"
)
for _ in {1..64}; do
  require_source_members_case "$source_archive" \
    scripts/ci/environment-k3d-run.sh \
    schemas/ci/diene-environment-report-v1.schema.json
done
if rg -n 'tar[[:space:]]+-tf[^|]*\|[[:space:]]*grep[^[:space:]]*[[:space:]]+-[^[:space:]]*q' \
  "$work/scripts/ci/environment-k3d-run.sh" >"$scratch/tar-grep-q"; then
  sed -n '1,120p' "$scratch/tar-grep-q" >&2
  fail 'a timing-sensitive tar-to-grep-q membership pipeline remains'
fi
ok '64 repeated source-archive checks consume one complete listing without SIGPIPE'
expect_refusal UntrustedSubject require_source_members_case "$source_archive" missing/driver.sh

printf '== checkpoint chains refuse broken, resumed, and retry-to-green tails ==\n'

checkpoint_validate_case() (
  # shellcheck source=/dev/null
  source "$work/scripts/ci/environment-lib.sh"
  diene_checkpoint_validate "${1:?checkpoint required}"
)
checkpoint_seal_final_case() (
  # shellcheck source=/dev/null
  source "$work/scripts/ci/environment-lib.sh"
  diene_checkpoint_seal "${1:?checkpoint required}" true
)

checkpoint_clean=$scratch/checkpoint-clean.json
(
  # shellcheck source=/dev/null
  source "$work/scripts/ci/environment-lib.sh"
  diene_checkpoint_init "$checkpoint_clean" "$ARTIFACT_DIGEST"
  diene_checkpoint_append "$checkpoint_clean" instance-preflight Pass "$ATTESTATION_DIGEST" false
  diene_checkpoint_append "$checkpoint_clean" environment-ready Pass "$CLOSURE_DIGEST" false
  diene_checkpoint_append "$checkpoint_clean" final-clean-pass Pass "$GARDEN_DIGEST" false
  diene_checkpoint_seal "$checkpoint_clean" true
)
jq -e '.validated == true and .resumedLegs == 0 and .finalCleanPass == true and
  (.checkpoints | length) == 3 and .checkpoints[-1].id == "final-clean-pass" and
  all(.checkpoints[]; .outcome == "Pass" and .resumed == false)' "$checkpoint_clean" >/dev/null ||
  fail 'a complete clean predecessor chain did not seal'
ok 'a complete non-resumed predecessor chain seals as the final clean full pass'

checkpoint_broken=$scratch/checkpoint-broken.json
cp "$checkpoint_clean" "$checkpoint_broken"
jq '.checkpoints[1].predecessorDigest = "sha256:9999999999999999999999999999999999999999999999999999999999999999"' \
  "$checkpoint_broken" >"$checkpoint_broken.tmp"
mv "$checkpoint_broken.tmp" "$checkpoint_broken"
expect_refusal CheckpointChainInvalid checkpoint_validate_case "$checkpoint_broken"

checkpoint_resumed=$scratch/checkpoint-resumed.json
(
  # shellcheck source=/dev/null
  source "$work/scripts/ci/environment-lib.sh"
  diene_checkpoint_init "$checkpoint_resumed" "$ARTIFACT_DIGEST"
  diene_checkpoint_append "$checkpoint_resumed" resumed-readiness Pass "$ATTESTATION_DIGEST" true
  diene_checkpoint_append "$checkpoint_resumed" final-clean-pass Pass "$GARDEN_DIGEST" false
  diene_checkpoint_seal "$checkpoint_resumed" false
)
expect_refusal FinalCleanPassRequired checkpoint_seal_final_case "$checkpoint_resumed"

checkpoint_failed=$scratch/checkpoint-failed.json
(
  # shellcheck source=/dev/null
  source "$work/scripts/ci/environment-lib.sh"
  diene_checkpoint_init "$checkpoint_failed" "$ARTIFACT_DIGEST"
  diene_checkpoint_append "$checkpoint_failed" failed-journey Fail "$ATTESTATION_DIGEST" false
  diene_checkpoint_append "$checkpoint_failed" final-clean-pass Pass "$GARDEN_DIGEST" false
  diene_checkpoint_seal "$checkpoint_failed" false
)
expect_refusal FinalCleanPassRequired checkpoint_seal_final_case "$checkpoint_failed"

checkpoint_no_final=$scratch/checkpoint-no-final.json
(
  # shellcheck source=/dev/null
  source "$work/scripts/ci/environment-lib.sh"
  diene_checkpoint_init "$checkpoint_no_final" "$ARTIFACT_DIGEST"
  diene_checkpoint_append "$checkpoint_no_final" environment-ready Pass "$GARDEN_DIGEST" false
  diene_checkpoint_seal "$checkpoint_no_final" false
)
expect_refusal FinalCleanPassRequired checkpoint_seal_final_case "$checkpoint_no_final"

for forged_kind in resumed failed; do
  forged_report=$scratch/forged-$forged_kind-report.json
  if [[ $forged_kind == resumed ]]; then
    jq '.checkpointChain.checkpoints[0].resumed = true' "$happy_core_report" >"$forged_report"
  else
    jq '.checkpointChain.checkpoints[0].outcome = "Fail"' "$happy_core_report" >"$forged_report"
  fi
  if "$validator" --base-uri "file://$schema_dir/" \
    --schemafile "$schema_dir/diene-environment-report-v1.schema.json" "$forged_report" >/dev/null 2>&1; then
    fail "a green Namespace report forged a $forged_kind checkpoint behind clean summary booleans"
  fi
done
ok 'green report schemas reject resumed or failed checkpoint entries behind forged clean summaries'

expect_lifecycle_failure 7201 checkpoint-broken CheckpointChainInvalid
! find "$FAILURE_NSC_ROOT/instances" -name live -print -quit | grep -q . ||
  fail 'broken predecessor evidence left its exact Namespace instance live'
expect_lifecycle_failure 7202 checkpoint-resumed FinalCleanPassRequired
! find "$FAILURE_NSC_ROOT/instances" -name live -print -quit | grep -q . ||
  fail 'resumed checkpoint evidence left its exact Namespace instance live'
expect_lifecycle_failure 7203 checkpoint-no-final FinalCleanPassRequired
! find "$FAILURE_NSC_ROOT/instances" -name live -print -quit | grep -q . ||
  fail 'missing final-clean evidence left its exact Namespace instance live'
ok 'broken, resumed, and incomplete checkpoint archives stay red after exact destroy and absence proof'

printf '\nenvironment contract checkpoint: PASS (%d checks)\n' "$passed"
