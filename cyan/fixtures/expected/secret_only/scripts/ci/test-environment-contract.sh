#!/usr/bin/env bash
# Local proof of the environment contract. It exercises the refusal surface,
# the happy path, evidence-on-failure, receipt exactness, two-run isolation and
# signal-safe cleanup against a fake `pls` that records every invocation, so a
# regression in the lane drivers fails here rather than on a disposable runner.
set -euo pipefail
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/../.." && pwd)
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT

work=$scratch/work
runner_temp=$scratch/runner
mkdir -p "$work/.diene/ci/fixtures/demo" "$runner_temp"
cp -r "$repo_root/schemas" "$work/schemas"
mkdir -p "$work/scripts/ci"
cp "$script_dir"/environment-*.sh "$work/scripts/ci/"

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
  local reason=$1
  shift
  if "$@" >"$scratch/stdout" 2>"$scratch/stderr"; then
    fail "expected $reason refusal but the command succeeded"
  fi
  grep -Fq -- "$reason" "$scratch/stderr" || {
    cat "$scratch/stderr" >&2
    fail "missing $reason evidence"
  }
  ok "refuses $reason"
}

# --- fake ratified Garden CLI ----------------------------------------------
# It implements only the ratified surface. Any invented verb makes it exit
# non-zero, so a driver that reaches for `pls env status|render|artifact|
# closure|network|vendor-policy` fails these tests by construction.
fake_pls=$scratch/pls
cat >"$fake_pls" <<'PLS'
#!/usr/bin/env bash
set -euo pipefail
printf '%q ' "$@" >>"${DIENE_TEST_PLS_LOG:?}"
printf '\n' >>"$DIENE_TEST_PLS_LOG"

allocation="r${GITHUB_REPOSITORY_ID}-w${GITHUB_RUN_ID}-a${GITHUB_RUN_ATTEMPT}-l${DIENE_LANE}"
[[ ${DIENE_LANE} != ditto-vendor ]] || allocation="${allocation}-v${DIENE_ACTION_ID}"
generation="g${GITHUB_SHA:0:12}"

case "$1 $2" in
  'env up')
    [[ " $* " == *" --artifact "* ]] || { printf 'ratified parser: --artifact is mandatory\n' >&2; exit 3; }
    profile=; mode=; artifact=
    while (($#)); do
      case $1 in
        --profile) profile=$2 ;;
        --build-mode) mode=$2 ;;
        --artifact) artifact=$2 ;;
      esac
      shift
    done
    if [[ ${DIENE_TEST_SLOW_UP:-0} == 1 ]]; then sleep 30; fi
    dir="${RUNNER_TEMP}/garden/${allocation}-${generation}"
    install -d -m 0700 "$dir"
    jq -n --arg profile "$profile" --arg mode "$mode" --arg artifact "$artifact" \
      --arg repositoryId "$GITHUB_REPOSITORY_ID" --arg repositoryKey "$GITHUB_REPOSITORY" \
      --arg allocationKey "$allocation" --arg generationKey "$generation" \
      '{apiVersion:"diene-runtime/v1",profile:$profile,buildMode:$mode,
        owner:{repositoryId:$repositoryId,repositoryKey:$repositoryKey,
               allocationKey:$allocationKey,generationKey:$generationKey},
        substrate:{kind:"k3d",name:("diene-"+$allocationKey),receipt:$allocationKey,
                   kubeconfig:"/tmp/kubeconfig",context:"k3d-diene"},
        artifact:{digest:$artifact}}' >"$dir/runtime.v1.json"
    chmod 0600 "$dir/runtime.v1.json"
    ;;
  'env doctor')
    profile=ditto
    while (($#)); do [[ $1 == --profile ]] && profile=$2; shift; done
    if [[ ${DIENE_TEST_EMPTY_READINESS:-0} == 1 ]]; then
      jq -n --arg profile "$profile" \
        '{apiVersion:"diene-readiness/v1",profile:$profile,aggregate:"EnvironmentReady",outcome:"Pass",readiness:[]}'
      exit 0
    fi
    seed_required=true
    [[ ${DIENE_LANE} == ditto-build-local || ${DIENE_LANE} == ditto-target-pull || ${DIENE_LANE} == ditto-vendor ]] || seed_required=false
    pull_required=false
    [[ ${DIENE_LANE} != ditto-target-pull ]] || pull_required=true
    jq -n --arg profile "$profile" --arg allocationKey "$allocation" \
      --argjson seedRequired "$seed_required" --argjson pullRequired "$pull_required" '
      def leaf($id; $required):
        if $required then
          {id:$id,outcome:"Pass",required:true,reasonCode:"Converged",
           sourceUid:"uid-"+$id,observedGeneration:1,allocationKey:$allocationKey,
           transitionTime:"2026-01-01T00:00:00Z"}
        else {id:$id,outcome:"NotRequired",required:false,reasonCode:"NotApplicableToLane"} end;
      {apiVersion:"diene-readiness/v1",profile:$profile,aggregate:"EnvironmentReady",outcome:"Pass",
       readiness:[
         leaf("SubstrateReady";true), leaf("SeedReady";$seedRequired), leaf("StoreReady";true),
         leaf("ExternalSecretsReady";true), leaf("DependenciesReady";true), leaf("PVCsReady";true),
         leaf("MigrationsReady";true), leaf("FixturesReady";true), leaf("LogtoReady";true),
         leaf("ArtifactPullReady";$pullRequired), leaf("ApplicationWorkloadsReady";true),
         leaf("ExposurePrerequisitesReady";true), leaf("ExposureReady";true), leaf("EnvironmentReady";true),
         leaf("AllocationReady";false), leaf("CastformProdSafetyReady";false), leaf("CallbackReady";false)
       ]}'
    ;;
  'env down')
    if [[ ${DIENE_TEST_FAIL_DOWN:-0} == 1 ]]; then
      printf 'injected exact-down failure\n' >&2
      exit 42
    fi
    ;;
  'env switch') ;;
  'closure preflight' | 'closure import') ;;
  *)
    printf 'unratified pls invocation: %s\n' "$*" >&2
    exit 127
    ;;
esac
PLS
chmod 0755 "$fake_pls"

fake_policy=$scratch/diene-host-policy
cat >"$fake_policy" <<'POLICY'
#!/usr/bin/env bash
set -euo pipefail
printf 'host-policy %q ' "$@" >>"${DIENE_TEST_PLS_LOG:?}"
printf '\n' >>"$DIENE_TEST_PLS_LOG"
POLICY
chmod 0755 "$fake_policy"

producer=$work/.diene/ci/artifact-producer.sh
cat >"$producer" <<'PRODUCER'
#!/usr/bin/env bash
set -euo pipefail
source_sha=; output=
while (($#)); do
  case $1 in
    --source-sha) source_sha=$2; shift 2 ;;
    --output) output=$2; shift 2 ;;
    *) shift ;;
  esac
done
digest="sha256:$(printf 'image-%s' "$source_sha" | sha256sum | cut -d' ' -f1)"
jq -n --arg sha "$source_sha" --arg digest "$digest" \
  --arg runId "${GITHUB_RUN_ID}" --arg runAttempt "${GITHUB_RUN_ATTEMPT}" \
  --arg workflowRef "${DIENE_BASE_WORKFLOW_REF}" \
  '{apiVersion:"diene.atomi.cloud/ci-artifact-subject/v1",sourceSha:$sha,
    artifact:{imageRef:("ghcr.io/atomicloud/example@"+$digest),digest:$digest,registry:"ghcr.io",
              producer:{workflowRef:$workflowRef,runId:$runId,runAttempt:$runAttempt}}}' >"$output"
PRODUCER
chmod 0755 "$producer"

export DIENE_TEST_PLS_LOG=$scratch/pls.log
: >"$DIENE_TEST_PLS_LOG"

cd "$work"
export RUNNER_TEMP=$runner_temp
export GITHUB_OUTPUT=$scratch/github-output
: >"$GITHUB_OUTPUT"
export GITHUB_REPOSITORY_ID=12345 GITHUB_REPOSITORY=AtomiCloud/example
export GITHUB_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
export GITHUB_RUN_ID=8001 GITHUB_RUN_ATTEMPT=1
export DIENE_PLS_BIN=$fake_pls
export DIENE_HOST_POLICY_BIN=$fake_policy
export DIENE_BASE_WORKFLOW_REF="AtomiCloud/example/.github/workflows/environment-k3d.yaml@$GITHUB_SHA"
export DIENE_LEAK_CANARY=canary-value-not-present
export DIENE_PREFLIGHT_HOST_CHECKS=0

lease=$scratch/lease.json
write_lease() {
  local job=$1
  jq -n --arg job "diene-job-r12345-w${GITHUB_RUN_ID}-a1-j$job" --arg sha "$GITHUB_SHA" \
    --argjson runId "$GITHUB_RUN_ID" '
    {apiVersion:"diene.atomi.cloud/ci-runner-lease/v1",repositoryId:12345,
     repositoryKey:"AtomiCloud/example",runId:$runId,runAttempt:1,sourceSha:$sha,state:"Online",
     labels:["self-hosted","linux","x64","diene-k3d-isolated-v1",$job]}' >"$lease"
  chmod 0600 "$lease"
  export DIENE_EXPECTED_JOB_ID=$job
}
write_lease environment-ditto-build-local
export DIENE_RUNNER_LEASE_FILE=$lease

# The lease is bound to this exact job, not merely to the run: a lease minted
# for a sibling lane of the same run is refused.
printf '== runner lease binds the exact job ==\n'
DIENE_EXPECTED_JOB_ID=environment-absol \
  expect_refusal RunnerIsolationUnavailable ./scripts/ci/environment-runner-preflight.sh
./scripts/ci/environment-runner-preflight.sh >/dev/null
ok 'a sibling lane lease is refused, the matching one is accepted'

DIENE_GARDEN_LOCK_DIGEST=sha256:$(printf garden | sha256sum | cut -d' ' -f1)
DIENE_ARTIFACT_DIGEST=sha256:$(printf artifact | sha256sum | cut -d' ' -f1)
export DIENE_GARDEN_LOCK_DIGEST DIENE_ARTIFACT_DIGEST
# The subject handoff carries image ref, producer identity and pull identity;
# they are deliberately not workflow_call inputs.
export DIENE_ARTIFACT_SUBJECT=$scratch/subject.v1.json
write_subject() {
  jq -n --arg sha "$GITHUB_SHA" --arg digest "$DIENE_ARTIFACT_DIGEST" \
    --arg runId "$GITHUB_RUN_ID" --arg runAttempt "$GITHUB_RUN_ATTEMPT" \
    --arg workflowRef "$DIENE_BASE_WORKFLOW_REF" --argjson provenance "${1:-null}" \
    '{apiVersion:"diene.atomi.cloud/ci-artifact-subject/v1",sourceSha:$sha,
      artifact:{imageRef:("ghcr.io/atomicloud/example@"+$digest),digest:$digest,registry:"ghcr.io",
                producer:{workflowRef:$workflowRef,runId:$runId,runAttempt:$runAttempt}}}
     + (if $provenance == null then {} else {provenance:$provenance} end)' \
    >"$DIENE_ARTIFACT_SUBJECT"
}
write_subject

printf '== profile and prerequisite gates ==\n'

# A repository that declared nothing is explicitly NotApplicable, never an
# implied pass.
DIENE_PROFILE_REPORT=$scratch/profile.json ./scripts/ci/environment-profile-contract.sh >/dev/null
jq -e '.outcome == "NotApplicable" and .reasonCode == "NoDeclaration"' "$scratch/profile.json" >/dev/null ||
  fail 'missing declaration was not reported NotApplicable'
ok 'no declaration is NotApplicable/NoDeclaration'

expect_refusal PreviewIdentityUnavailable ./scripts/ci/environment-profile-contract.sh --render-profile castform
expect_refusal ProfileRenderInterfaceUnavailable ./scripts/ci/environment-profile-contract.sh --render-profile ditto

export DIENE_LANE=ditto-build-local
export DIENE_JOURNEY_MANIFEST=.diene/ci/journeys.v1.yaml
unset DIENE_VENDOR_MANIFEST DIENE_ACTION_ID DIENE_FIXTURE_ID DIENE_SEED_IDENTITY 2>/dev/null || true

# Release boundary: a missing controller/image pin refuses on the
# GitHub-hosted path, before any runner could be selected.
expect_refusal RunnerIsolationUnavailable ./scripts/ci/environment-profile-contract.sh --validate-prerequisites
jq -n '{apiVersion:"diene.atomi.cloud/ci-runner-pin/v1",
  controller:{release:"diene-ci-runner/v1",
    digest:"sha256:1111111111111111111111111111111111111111111111111111111111111111",
    signatureDigest:"sha256:2222222222222222222222222222222222222222222222222222222222222222"},
  image:{name:"diene-k3d-isolated-v1",
    digest:"sha256:3333333333333333333333333333333333333333333333333333333333333333",
    lockDigest:"sha256:4444444444444444444444444444444444444444444444444444444444444444"},
  provisionerReady:{accepted:true,
    evidenceDigest:"sha256:5555555555555555555555555555555555555555555555555555555555555555"}}' \
  >.diene/ci/runner-pin.v1.json
./scripts/ci/environment-profile-contract.sh --validate-prerequisites >/dev/null
ok 'accepted runner pin and producer satisfy the release boundary'

printf '== subject handoff ==\n'

subject=$scratch/artifact.v1.json
./.diene/ci/artifact-producer.sh --source-sha "$GITHUB_SHA" --output "$subject"
./scripts/ci/environment-profile-contract.sh --validate-subject "$subject" >/dev/null
ok 'a same-run producer output is accepted'

# A checked-in declaration goes stale: its producer run cannot bind this run.
jq '.artifact.producer.runId = "7"' "$subject" >"$scratch/stale.json"
expect_refusal UntrustedSubject ./scripts/ci/environment-profile-contract.sh --validate-subject "$scratch/stale.json"

printf '== input contract ==\n'

DIENE_BASE_WORKFLOW_REF="AtomiCloud/example/.github/workflows/environment-k3d.yaml@bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" \
  expect_refusal UntrustedSubject ./scripts/ci/environment-k3d-run.sh --validate-inputs
: >"$DIENE_TEST_PLS_LOG"
attest="sha256:$(printf attest | sha256sum | cut -d' ' -f1)"

# A puller identity equal to the publisher is refused, and the identity comes
# from the validated subject document rather than a caller-supplied input.
write_subject "$(jq -nc --arg attest "$attest" --arg workflowRef "$DIENE_BASE_WORKFLOW_REF" \
  '{predicateType:"https://slsa.dev/provenance/v1",provenanceRef:"https://example/prov",
    attestationDigest:$attest,workflowRef:$workflowRef,runId:"8001",runAttempt:"1",
    pullIdentity:$workflowRef}')"
DIENE_LANE=ditto-target-pull \
  DIENE_ARTIFACT_ATTESTATION_DIGEST="$attest" \
  DIENE_ARTIFACT_PROVENANCE_REF="https://example/prov" \
  expect_refusal UntrustedSubject ./scripts/ci/environment-k3d-run.sh --validate-inputs

# A caller-substituted provenance selector cannot override the published one.
write_subject "$(jq -nc --arg attest "$attest" --arg workflowRef "$DIENE_BASE_WORKFLOW_REF" \
  '{predicateType:"https://slsa.dev/provenance/v1",provenanceRef:"https://example/prov",
    attestationDigest:$attest,workflowRef:$workflowRef,runId:"8001",runAttempt:"1",
    pullIdentity:"ghcr-reader-identity"}')"
DIENE_LANE=ditto-target-pull \
  DIENE_ARTIFACT_ATTESTATION_DIGEST="$attest" \
  DIENE_ARTIFACT_PROVENANCE_REF="https://attacker/prov" \
  expect_refusal UntrustedSubject ./scripts/ci/environment-k3d-run.sh --validate-inputs

# A subject that binds a different run cannot be replayed into this one.
jq '.artifact.producer.runAttempt = "9"' "$DIENE_ARTIFACT_SUBJECT" >"$scratch/replay.json"
DIENE_ARTIFACT_SUBJECT="$scratch/replay.json" \
  expect_refusal UntrustedSubject ./scripts/ci/environment-k3d-run.sh --validate-inputs
write_subject
[[ ! -s $DIENE_TEST_PLS_LOG ]] || fail 'a refusal reached the substrate'
ok 'refusals never touch the substrate'

printf '== workflow ABI is exactly the ratified set ==\n'
reusable=$repo_root/.github/workflows/⚡reusable-environment-k3d.yaml
declared=$(awk '/^    inputs:$/{f=1;next} /^    outputs:$/{f=0} f && /^      [a-z_]+:/{gsub(/[ :]/,"",$1);print $1}' "$reusable" | sort)
expected=$(printf '%s\n' lane repository_id repository_key source_sha garden_lock_digest \
  artifact_digest artifact_provenance_ref artifact_attestation_digest journey_manifest \
  vendor_manifest action_id closure_digest closure_bundle_ref closure_signature_bundle_digest \
  closure_trust_root_digest | sort)
[[ $declared == "$expected" ]] || {
  diff <(printf '%s\n' "$expected") <(printf '%s\n' "$declared") >&2
  fail 'the reusable workflow_call ABI drifted from the ratified input set'
}
ok 'workflow_call exposes exactly the ratified diene-ci-k3d/v1 inputs'

for lane in ditto-build-local ditto-target-pull ditto-vendor absol fleet-independence; do
  group="k3d-\${{ inputs.repository_id }}-\${{ github.run_id }}-\${{ github.run_attempt }}-$lane"
  [[ $lane != ditto-vendor ]] || group="$group-\${{ inputs.action_id }}"
  grep -Fq "group: $group" "$reusable" || fail "lane $lane lacks its exact per-run concurrency group"
done
ok 'all five lanes carry their exact run-scoped concurrency group'

grep -Fq 'environment: ci-ditto' "$reusable" || fail 'the fleet lane lost its exact environment'
! grep -Fq 'ci-ditto-independence' "$reusable" || fail 'the fleet lane invented a new environment name'
ok 'fleet independence uses the exact ci-ditto environment'

printf '== schema validation precedes every pls call ==\n'

cat >.diene/ci/environment-lock.v1.json <<'JSON'
{
  "apiVersion":"diene.atomi.cloud/environment-lock/v1",
  "profiles":{
    "lapras":{"substrate":"k3d"},"ditto":{"substrate":"k3d"},"rotom":{"substrate":"k3d"},"absol":{"substrate":"k3d"},
    "eevee":{"substrate":"entei-vcluster"},"castform":{"substrate":"entei-vcluster"}
  },
  "previewManifest":{"schemaVersion":"preview-manifest/v1","schemaDigest":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","wordListVersion":"v1"},
  "operator":{"kind":"operator","version":"1.0.0"}
}
JSON

# A declaration that the old ad-hoc jq shape check would have accepted is now
# refused by the real schema: this entry is missing poll/readinessLeaves/
# assertions/safeReportFields.
cat >.diene/ci/journeys.v1.yaml <<'JSON'
{"apiVersion":"diene.atomi.cloud/ci-journeys/v1","journeys":[{
  "id":"demo","componentClass":"K1","required":true,
  "appliesTo":[{"lane":"ditto-build-local","profile":"ditto","buildMode":"build-local"}],
  "fixturePack":{"id":"demo","version":"1.0.0","digest":"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"},
  "setup":["/bin/true"],"probe":["/bin/true"],"cleanup":["/bin/true"],
  "workingDirectory":".","timeoutSeconds":60}]}
JSON
: >"$DIENE_TEST_PLS_LOG"
expect_refusal SchemaValidationFailed ./scripts/ci/environment-k3d-run.sh
[[ ! -s $DIENE_TEST_PLS_LOG ]] || fail 'an invalid declaration reached pls'
ok 'an invalid declaration never reaches pls'

# A well-formed declaration, with a fixture pack whose digest is real.
printf '%s\n' '{"apiVersion":"diene.atomi.cloud/ci-fixture/v1","id":"demo"}' >.diene/ci/fixtures/demo/manifest.yaml
pack_digest="sha256:$(sha256sum .diene/ci/fixtures/demo/manifest.yaml | cut -d' ' -f1)"
write_journeys() {
  local probe=$1
  jq -n --arg digest "$pack_digest" --arg probe "$probe" '
  {apiVersion:"diene.atomi.cloud/ci-journeys/v1",journeys:[{
    id:"demo",componentClass:"K1",required:true,
    appliesTo:[{lane:"ditto-build-local",profile:"ditto",buildMode:"build-local"}],
    fixturePack:{id:"demo",version:"1.0.0",digest:$digest},
    setup:["/bin/true"],probe:[$probe],cleanup:["/bin/true"],
    workingDirectory:".",timeoutSeconds:60,
    poll:{intervalSeconds:5,attempts:12},
    readinessLeaves:["EnvironmentReady"],assertions:["demo responds"],safeReportFields:["id"]}]}' \
    >.diene/ci/journeys.v1.yaml
}
write_journeys /bin/true

printf '== happy path ==\n'

: >"$DIENE_TEST_PLS_LOG"
export DIENE_CORE_REPORT=$scratch/core-report.json
./scripts/ci/environment-k3d-run.sh >/dev/null
jq -e '.outcome == "Pass" and .teardown.outcome == "Pass" and
       .teardown.absenceProof == "ReceiptDestroyed" and
       .journeys[0].outcome == "Pass" and
       (.readiness.readiness | length) == 17 and
       .evidence.leakageScan.outcome == "Pass" and
       (.evidence.leakageScan.encodings | length) == 6 and
       .evidence.egressCanary.mode == "allowlist" and
       .subject.imageRef != null and .timings.substrateSeconds >= 0' \
  "$DIENE_CORE_REPORT" >/dev/null || fail 'happy-path report is incomplete'
ok 'happy path emits a complete, schema-valid report'

grep -Fq -- 'env up --profile ditto --build-mode build-local --artifact' "$DIENE_TEST_PLS_LOG" ||
  fail 'env up was called without the mandatory --artifact'
ok 'env up carries the mandatory --artifact'
grep -Fq -- 'env down --profile ditto' "$DIENE_TEST_PLS_LOG" || fail 'exact teardown was not driven'
ok 'exact teardown is driven through the ratified down'
grep -Fq 'host-policy apply' "$DIENE_TEST_PLS_LOG" || fail 'host policy was never applied'
grep -Fq 'host-policy release' "$DIENE_TEST_PLS_LOG" || fail 'host policy was never released'
ok 'egress posture is applied before and released after teardown'

# The ratified surface is the only surface. The fake exits 127 on anything
# else, so a reintroduced `pls env status|render|artifact|network` would have
# already failed the happy path above.
! grep -Eq 'env (status|render|artifact|network|vendor-policy)' "$DIENE_TEST_PLS_LOG" ||
  fail 'an unratified pls verb was invoked'
ok 'no unratified pls verb is invoked'

printf '== evidence on failure ==\n'

write_journeys /bin/false
failed_report=$scratch/failed-core-report.json
: >"$DIENE_TEST_PLS_LOG"
if DIENE_CORE_REPORT=$failed_report ./scripts/ci/environment-k3d-run.sh >/dev/null 2>&1; then
  fail 'a failing journey did not fail the lane'
fi
[[ -f $failed_report ]] || fail 'a failing run produced no evidence'
jq -e '.outcome == "Fail" and .reasonCode == "JourneyFailed" and
       .journeys[0].outcome == "Fail" and .journeys[0].reasonCode == "ProbeFailed" and
       .teardown.absenceProof == "ReceiptDestroyed"' "$failed_report" >/dev/null ||
  fail 'the failing report does not carry its verdict, journey and teardown evidence'
ok 'a red run still publishes readiness, journey and teardown evidence'
write_journeys /bin/true

printf '== vacuous readiness ==\n'

: >"$DIENE_TEST_PLS_LOG"
DIENE_TEST_EMPTY_READINESS=1 DIENE_CORE_REPORT=$scratch/empty.json \
  expect_refusal SchemaValidationFailed ./scripts/ci/environment-k3d-run.sh

printf '== leak canary ==\n'

: >"$DIENE_TEST_PLS_LOG"
canary_report=$scratch/canary-report.json
(
  unset DIENE_LEAK_CANARY
  DIENE_CORE_REPORT=$canary_report ./scripts/ci/environment-k3d-run.sh >"$scratch/stdout" 2>"$scratch/stderr"
) && fail 'a missing canary published unscanned evidence'
grep -Fq EvidenceLeakDetected "$scratch/stderr" || fail 'a missing canary was not fail-closed'
[[ ! -e $canary_report ]] || fail 'an unscanned report survived'
ok 'an absent canary fails closed and suppresses the artifact'

leak_raw=$scratch/leak-raw.json
jq '.evidence.egressCanary.reasonCode = "leaky-canary-token"' "$DIENE_CORE_REPORT" >"$leak_raw"
DIENE_LEAK_CANARY=leaky-canary-token \
  expect_refusal EvidenceLeakDetected ./scripts/ci/environment-report.sh \
  --kind core --input "$leak_raw" --output "$scratch/leak.json"
[[ ! -e $scratch/leak.json ]] || fail 'a leaking report survived'
ok 'a positive canary suppresses the artifact'

printf '== report namespaces are disjoint ==\n'

expect_refusal ReportNamespaceViolation ./scripts/ci/environment-report.sh \
  --kind vendor --input "$DIENE_CORE_REPORT" --output "$scratch/wrong.json"

printf '== receipt exactness ==\n'

receipt_dir=$scratch/receipts
mkdir -p "$receipt_dir"
runtime=$scratch/runtime.json
write_runtime() {
  jq -n --arg allocationKey "$1" --arg generationKey "$2" \
    '{apiVersion:"diene-runtime/v1",profile:"ditto",buildMode:"build-local",
      owner:{repositoryId:"12345",repositoryKey:"AtomiCloud/example",
             allocationKey:$allocationKey,generationKey:$generationKey},
      substrate:{kind:"k3d",name:"diene-x",receipt:"x"},
      artifact:{digest:"sha256:0000000000000000000000000000000000000000000000000000000000000000"}}' >"$runtime"
  chmod 0600 "$runtime"
}
write_receipt() {
  # receiptId, allocationKey, generationKey, runtimeFile, fileName
  jq -n --arg runtimeFile "$4" --arg receiptId "$1" --arg allocationKey "$2" --arg generationKey "$3" \
    '{apiVersion:"diene.atomi.cloud/ci-receipt/v1",
      owner:{repositoryId:"12345",repositoryKey:"AtomiCloud/example",
             sourceSha:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",runId:"8001",runAttempt:"1",
             receiptId:$receiptId,allocationKey:$allocationKey,generationKey:$generationKey,
             workflowRef:"AtomiCloud/example/.github/workflows/environment-k3d.yaml@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},
      lane:"ditto-build-local",profile:"ditto",buildMode:"build-local",
      runtimeFile:(if $runtimeFile == "" then null else $runtimeFile end),
      cleanup:{outcome:"Pending",reasonCode:"RuntimeArmed",debt:[]}}' \
    >"$receipt_dir/$5.json"
  chmod 0600 "$receipt_dir/$5.json"
}
alloc_a=r12345-w8001-a1-lditto-build-local
alloc_b=r12345-w8001-a1-labsol
gen=gaaaaaaaaaaaa
write_runtime "$alloc_a" "$gen"

# A sibling owner tuple is refused without touching pls.
write_receipt "$alloc_a-$gen" "$alloc_a" "$gen" "$runtime" one
: >"$DIENE_TEST_PLS_LOG"
expect_refusal CleanupDebt env DIENE_RECEIPT_DIR="$receipt_dir" ./scripts/ci/environment-receipt-sweep.sh \
  --repository-id 12345 --run-id 9999 --run-attempt 1 --receipt-id "$alloc_a-$gen"
[[ ! -s $DIENE_TEST_PLS_LOG ]] || fail 'a sibling receipt was touched'
ok 'a sibling owner tuple is refused with no deletion'

# An unbound runtime file authorises nothing: no profile-only teardown.
write_receipt "$alloc_b-$gen" "$alloc_b" "$gen" "" unbound
: >"$DIENE_TEST_PLS_LOG"
expect_refusal CleanupDebt env DIENE_RECEIPT_DIR="$receipt_dir" ./scripts/ci/environment-receipt-sweep.sh \
  --repository-id 12345 --run-id 8001 --run-attempt 1 --receipt-id "$alloc_b-$gen"
[[ ! -s $DIENE_TEST_PLS_LOG ]] || fail 'an unbound receipt triggered a profile-only teardown'
ok 'an unbound runtime file becomes visible debt, never a profile-only teardown'

# Two concurrent lanes of one run keep distinct receipts, and sweeping one
# leaves the other untouched.
: >"$DIENE_TEST_PLS_LOG"
DIENE_RECEIPT_DIR="$receipt_dir" ./scripts/ci/environment-receipt-sweep.sh \
  --repository-id 12345 --run-id 8001 --run-attempt 1 --receipt-id "$alloc_a-$gen" >/dev/null
jq -e '.cleanup.outcome == "Pass"' "$receipt_dir/one.json" >/dev/null || fail 'the swept receipt was not destroyed'
jq -e '.cleanup.outcome == "Pending"' "$receipt_dir/unbound.json" >/dev/null 2>&1 ||
  jq -e '.cleanup.outcome == "Fail"' "$receipt_dir/unbound.json" >/dev/null ||
  fail "one lane's sweep mutated the sibling lane"
ok 'two-run isolation: one lane sweep never touches the sibling receipt'

# The always() post-job sweep must not issue a second teardown.
: >"$DIENE_TEST_PLS_LOG"
DIENE_RECEIPT_DIR="$receipt_dir" ./scripts/ci/environment-receipt-sweep.sh \
  --repository-id 12345 --run-id 8001 --run-attempt 1 --receipt-id "$alloc_a-$gen" >/dev/null
[[ ! -s $DIENE_TEST_PLS_LOG ]] || fail 'a destroyed receipt was torn down twice'
ok 'sweeping is idempotent: no double down'

printf '== signal-safe cleanup ==\n'

# Cleanup is armed before the substrate mutation, so a cancellation inside the
# long `pls env up` still converges instead of orphaning the cluster.
: >"$DIENE_TEST_PLS_LOG"
sig_temp=$scratch/sig-runner
mkdir -p "$sig_temp"
# setsid puts the lane in its own process group so the TERM below reaches the
# driver and its children exactly the way a cancelled job does.
setsid env \
  RUNNER_TEMP="$sig_temp" \
  DIENE_TEST_SLOW_UP=1 \
  DIENE_CORE_REPORT="$scratch/sig-report.json" \
  ./scripts/ci/environment-k3d-run.sh >/dev/null 2>&1 &
sig_pid=$!

# Wait until the mutation is genuinely in flight before cancelling.
waited=0
while ((waited < 20)); do
  grep -Fq 'env up' "$DIENE_TEST_PLS_LOG" && break
  sleep 1
  waited=$((waited + 1))
done
grep -Fq 'host-policy apply' "$DIENE_TEST_PLS_LOG" ||
  fail 'the egress posture was not armed before the substrate mutation'
ok 'posture and receipt are armed before the substrate mutation'

kill -TERM -"$sig_pid" 2>/dev/null || kill -TERM "$sig_pid" 2>/dev/null || true
wait "$sig_pid" 2>/dev/null || true

grep -Fq 'host-policy release' "$DIENE_TEST_PLS_LOG" ||
  fail 'a cancelled run left its host egress posture applied'
ok 'cancellation inside env up still releases the egress posture'

# The receipt was written before the mutation, so the cancelled run is
# recoverable by owner tuple and its debt is visible rather than silent.
sig_receipt=$(find "$sig_temp/diene-receipts" -name '*.json' -print -quit 2>/dev/null || true)
[[ -n $sig_receipt ]] || fail 'a cancelled run left no receipt to sweep'
jq -e '.owner.allocationKey == "r12345-w8001-a1-lditto-build-local" and .cleanup.outcome != "Pass"' \
  "$sig_receipt" >/dev/null || fail 'the cancelled run receipt is not exact or was falsely marked destroyed'
ok 'a cancelled run leaves an exact, lane-scoped receipt carrying visible debt'

printf '== vendor class admission ==\n'

cat >.diene/ci/vendors.v1.yaml <<'JSON'
{"apiVersion":"diene.atomi.cloud/ci-vendors/v1","actions":[{
  "componentClass":"K9","actionId":"forbidden","permissionRule":"ditto-vendor-demo",
  "profile":"ditto","buildMode":"build-local","required":true,
  "fixturePack":{"id":"demo","version":"1.0.0","digest":"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"},
  "account":"sandbox-demo","endpoint":"https://sandbox.example.com",
  "credentialEnv":"DIENE_VENDOR_CREDENTIAL","credentialWriter":"github-environment",
  "egress":[{"dns":"sandbox.example.com","sni":"sandbox.example.com","port":443,"methods":["GET"]}],
  "setup":["/bin/true"],"probe":["/bin/true"],"cleanup":["/bin/true"],"absence":["/bin/true"],
  "timeoutSeconds":60,"retryAttempts":0,"callbackCompletion":"poll"}]}
JSON
# A class that the segment authority has not admitted is refused before any
# credential, egress or substrate mutation.
jq '.actions[0].componentClass = "K10" | .actions[0].permissionRule = "off"' \
  .diene/ci/vendors.v1.yaml >"$scratch/bad-vendors.json"
cp "$scratch/bad-vendors.json" .diene/ci/vendors.v1.yaml
: >"$DIENE_TEST_PLS_LOG"
write_lease environment-ditto-vendor
(
  export DIENE_LANE=ditto-vendor DIENE_VENDOR_MANIFEST=.diene/ci/vendors.v1.yaml DIENE_ACTION_ID=forbidden
  unset DIENE_JOURNEY_MANIFEST
  ./scripts/ci/environment-vendor-run.sh
) >"$scratch/stdout" 2>"$scratch/stderr" && fail 'an unauthorized vendor class was admitted'
grep -Eq 'SchemaValidationFailed|VendorClassNotAuthorized' "$scratch/stderr" ||
  fail 'an unauthorized vendor class produced no stable refusal'
[[ ! -s $DIENE_TEST_PLS_LOG ]] || fail 'an unauthorized vendor mutated policy or substrate'
ok 'an unauthorized vendor class refuses before any mutation'

printf '\nenvironment contract tests: PASS (%d checks)\n' "$passed"
