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

# A stand-in for the root-owned broker. It models the ABI only: the real
# boundary lives in a host layer the job cannot reach, which is precisely why
# the lane refuses when the broker is absent.
fake_policy=$scratch/diene-host-policy-broker
cat >"$fake_policy" <<'POLICY'
#!/usr/bin/env bash
set -euo pipefail
printf 'host-policy %q ' "$@" >>"${DIENE_TEST_PLS_LOG:?}"
printf '\n' >>"$DIENE_TEST_PLS_LOG"
case ${1:-} in
  routes)
    posture=hermetic
    while (($#)); do [[ $1 == --posture ]] && posture=$2; shift; done
    # The receipt-assigned routes are issued by the broker, never copied from
    # a stale constant in the template.
    if [[ $posture == connected ]]; then
      jq -nc '{allow:["127.0.0.0/8","10.202.0.0/24","10.203.0.0/16","ghcr.io:443","seed.internal:443"],
               denyDns:true,denyDefaultRoute:true}'
    else
      jq -nc '{allow:["127.0.0.0/8","10.202.0.0/24","10.203.0.0/16"],denyDns:true,denyDefaultRoute:true}'
    fi
    ;;
  verify)
    # The host layer attests the posture was held for the lane's lifetime.
    [[ ${DIENE_TEST_POSTURE_BROKEN:-0} != 1 ]]
    ;;
esac
POLICY
chmod 0755 "$fake_policy"

fake_pull_proof=$scratch/diene-artifact-pull-proof
cat >"$fake_pull_proof" <<'PULL'
#!/usr/bin/env bash
set -euo pipefail
printf 'pull-proof %q ' "$@" >>"${DIENE_TEST_PLS_LOG:?}"
printf '\n' >>"$DIENE_TEST_PLS_LOG"
[[ ${DIENE_TEST_FAIL_PULL_PROOF:-} != "$1" ]]
PULL
chmod 0755 "$fake_pull_proof"

fake_closure_verify=$scratch/diene-closure-verify
cat >"$fake_closure_verify" <<'CLOSURE'
#!/usr/bin/env bash
set -euo pipefail
printf 'closure-verify %q ' "$@" >>"${DIENE_TEST_PLS_LOG:?}"
printf '\n' >>"$DIENE_TEST_PLS_LOG"
[[ ${DIENE_TEST_FAIL_CLOSURE:-} != "$1" ]]
CLOSURE
chmod 0755 "$fake_closure_verify"

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
export DIENE_HOST_POLICY_BROKER_BIN=$fake_policy
export DIENE_PULL_PROOF_BIN=$fake_pull_proof
export DIENE_CLOSURE_VERIFY_BIN=$fake_closure_verify
export DIENE_BASE_WORKFLOW_REF="AtomiCloud/example/.github/workflows/environment-k3d.yaml@$GITHUB_SHA"
export DIENE_LEAK_CANARY=canary-value-not-present
export DIENE_PREFLIGHT_HOST_CHECKS=0

# The runner arm exports the job-visible lease projection: exactly mode 0440
# at the .public.json path. The fake overrides the path but models the same
# ABI, so a drift in either arm fails here.
lease=$scratch/diene-runner-lease.v1.public.json
write_lease() {
  local job=$1
  # The projection is read-only once written, so replace it rather than
  # rewriting it in place.
  rm -f -- "$lease"
  jq -n --arg job "diene-job-r12345-w${GITHUB_RUN_ID}-a1-j$job" --arg sha "$GITHUB_SHA" \
    --argjson runId "$GITHUB_RUN_ID" '
    {apiVersion:"diene.atomi.cloud/ci-runner-lease/v1",repositoryId:12345,
     repositoryKey:"AtomiCloud/example",runId:$runId,runAttempt:1,sourceSha:$sha,state:"Online",
     labels:["self-hosted","linux","x64","diene-k3d-isolated-v1",$job]}' >"$lease"
  chmod 0440 "$lease"
  export DIENE_EXPECTED_JOB_ID=$job
}
write_lease environment-ditto-build-local
export DIENE_RUNNER_LEASE_FILE=$lease

printf '== runner lease cross-arm ABI ==\n'
./scripts/ci/environment-runner-preflight.sh >/dev/null
ok 'the 0440 job-visible lease projection is accepted'

# A private-lease mode is not the job-visible projection and must refuse, so
# the two arms cannot silently disagree about which file a job reads.
chmod 0600 "$lease"
expect_refusal RunnerIsolationUnavailable ./scripts/ci/environment-runner-preflight.sh
chmod 0440 "$lease"

grep -Fq '/run/diene-runner-lease.v1.public.json' ./scripts/ci/environment-runner-preflight.sh ||
  fail 'the preflight does not default to the job-visible lease projection path'
ok 'the default lease path is the job-visible projection'

# The job identity holds CAP_NET_ADMIN and is denied CAP_SYS_ADMIN, so a
# successful `unshare --net` is a failure signal, never a requirement.
grep -Fq 'job identity holds CAP_SYS_ADMIN' ./scripts/ci/environment-runner-preflight.sh ||
  fail 'the preflight does not refuse a job that holds CAP_SYS_ADMIN'
! grep -Eq '^ *unshare --net true \|\| diene_die' ./scripts/ci/environment-runner-preflight.sh ||
  fail 'the preflight still requires CAP_SYS_ADMIN via unshare'
ok 'capability proof is CAP_NET_ADMIN present and CAP_SYS_ADMIN absent'

# The lease is bound to this exact job, not merely to the run: a lease minted
# for a sibling lane of the same run is refused.
DIENE_EXPECTED_JOB_ID=environment-absol \
  expect_refusal RunnerIsolationUnavailable ./scripts/ci/environment-runner-preflight.sh
export DIENE_EXPECTED_JOB_ID=environment-ditto-build-local
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

# An absent subject is a stable refusal, never a quiet pass.
expect_refusal ArtifactProducerUnavailable \
  ./scripts/ci/environment-profile-contract.sh --validate-subject "$scratch/no-such-subject.json"

# A non-executable producer refuses before anything else.
chmod -x .diene/ci/artifact-producer.sh
expect_refusal ArtifactProducerUnavailable ./scripts/ci/environment-profile-contract.sh --validate-prerequisites
chmod +x .diene/ci/artifact-producer.sh

printf '== one subject rail, no quiet pass ==\n'
ci_workflow=$repo_root/.github/workflows/ci.yaml
grep -Fq 'ArtifactProducerUnavailable' "$ci_workflow" ||
  fail 'ci.yaml artifact-build does not refuse a missing producer with a stable reason'
! grep -Fq 'NoDeclaration: ' "$ci_workflow" ||
  fail 'ci.yaml artifact-build still passes quietly when the producer is absent'
ok 'artifact-build refuses ArtifactProducerUnavailable instead of passing quietly'

# artifact-build must publish, and every same-run consumer must download, the
# one immutable subject. A consumer that re-derives one is a second rail.
grep -Fq "name: diene-artifact-subject-\${{ github.run_id }}-\${{ github.run_attempt }}" "$ci_workflow" ||
  fail 'ci.yaml does not publish/consume the same-run subject handoff'
for workflow in "$ci_workflow" "$repo_root/.github/workflows/environment-k3d.yaml"; do
  uploads=$(grep -c 'actions/upload-artifact' "$workflow" || true)
  producer_runs=$(grep -c 'artifact-producer.sh --source-sha' "$workflow" || true)
  ((producer_runs <= 1)) ||
    fail "$(basename "$workflow") invokes the producer more than once; that is a second subject rail"
  ((uploads >= 1)) || fail "$(basename "$workflow") publishes no evidence"
done
ok 'the subject is produced once per run and consumed as a published handoff'

printf '== caller ABI: never skip green ==\n'
k3d_workflow=$repo_root/.github/workflows/environment-k3d.yaml
vendor_workflow=$repo_root/.github/workflows/environment-vendor.yaml

# Only a missing journey declaration may disable the runtime callers. Every
# other prerequisite must refuse in a runtime-free job, never skip green.
for declaration in environment-lock runner-pin artifact-producer; do
  ! grep -A6 'enabled=true' "$k3d_workflow" | grep -Fq "$declaration" ||
    fail "a missing $declaration still disables the runtime callers instead of refusing"
done
grep -Fq 'journeys.v1.yaml' "$k3d_workflow" || fail 'the journey declaration gate is gone'
ok 'only an absent journey declaration disables the callers; the rest refuse'

# Absol must not be silently omitted when the closure is incomplete.
! grep -Fq 'absol_ready' "$k3d_workflow" ||
  fail 'environment-absol is still skipped on an incomplete closure'
ok 'Absol is gated by the trigger matrix alone, never by closure presence'

# Declaring the Absol lane without a complete signed closure refuses in the
# runtime-free gate rather than dropping environment-absol from the build.
write_subject
jq -n '{apiVersion:"diene.atomi.cloud/ci-journeys/v1",journeys:[{
  id:"absol-demo",componentClass:"K1",required:true,
  appliesTo:[{lane:"absol",profile:"absol",buildMode:"build-local"}],
  fixturePack:{id:"demo",version:"1.0.0",digest:"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"},
  setup:["/bin/true"],probe:["/bin/true"],cleanup:["/bin/true"],
  workingDirectory:".",timeoutSeconds:60,poll:{intervalSeconds:5,attempts:12},
  readinessLeaves:["EnvironmentReady"],assertions:["a"],safeReportFields:["id"]}]}' \
  >"$scratch/absol-journeys.json"
DIENE_JOURNEY_MANIFEST="$scratch/absol-journeys.json" \
  expect_refusal RequiredCoverageUnavailable \
  ./scripts/ci/environment-profile-contract.sh --validate-subject "$DIENE_ARTIFACT_SUBJECT"

# Fleet independence accepts an authorized rerun; the schedule reaches it alone.
grep -Fq "github.event_name == 'workflow_dispatch'" "$k3d_workflow" ||
  fail 'no lane accepts an authorized dispatch'
schedule_lanes=$(grep -c "github.event_name == 'schedule'" "$k3d_workflow" || true)
((schedule_lanes == 1)) || fail "the schedule reaches $schedule_lanes lanes, expected exactly fleet independence"
ok 'the schedule reaches fleet independence alone, which also accepts an authorized rerun'

# Both profile gates carry the exact timeout and concurrency group.
for workflow in "$ci_workflow" "$k3d_workflow" "$vendor_workflow"; do
  grep -Fq 'timeout-minutes: 20' "$workflow" ||
    fail "$(basename "$workflow") profile gate lacks the exact 20-minute timeout"
  grep -Fq 'group: profile-' "$workflow" ||
    fail "$(basename "$workflow") profile gate lacks its profile concurrency group"
done
ok 'every profile gate carries the 20-minute timeout and profile concurrency group'

# The vendor caller keeps the stable prerequisite job IDs.
for job in 'artifact-build:' 'environment-profile-contract:' 'environment-ditto-vendor:'; do
  grep -Fq "  $job" "$vendor_workflow" || fail "the vendor caller lost the stable $job job"
done
grep -Fq 'needs: [authorize-vendor, artifact-build, environment-profile-contract]' "$vendor_workflow" ||
  fail 'the vendor lane does not need both stable prerequisites'
ok 'the vendor caller preserves the stable artifact-build and profile-contract prerequisites'

# A 40-character ref name must never pass as a commit SHA.
for workflow in "$k3d_workflow" "$vendor_workflow"; do
  grep -Fq '=~ ^[0-9a-f]{40}$' "$workflow" ||
    fail "$(basename "$workflow") accepts any 40-character string as a commit"
  grep -Fq 'git cat-file -e' "$workflow" ||
    fail "$(basename "$workflow") does not prove the commit resolves"
  grep -Fq 'merge-base --is-ancestor' "$workflow" ||
    fail "$(basename "$workflow") does not prove reachability from the protected branch"
done
ok 'dispatch guards require a full lowercase 40-hex reachable commit'

# The empty top-level default is preserved everywhere.
for workflow in "$ci_workflow" "$k3d_workflow" "$vendor_workflow" \
  "$repo_root/.github/workflows/⚡reusable-environment-k3d.yaml"; do
  grep -Fq 'permissions: {}' "$workflow" ||
    fail "$(basename "$workflow") lost its empty top-level permissions default"
done
ok 'every workflow keeps the empty top-level permissions default'

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
       (.evidence.leakageScan.scannedPaths | length) >= 3 and
       .evidence.egressCanary.mode == "connected" and
       .evidence.egressCanary.reasonCode == "HostAttestedPostureSustained" and
       .subject.imageRef != null and .timings.substrateSeconds >= 0' \
  "$DIENE_CORE_REPORT" >/dev/null || fail 'happy-path report is incomplete'
ok 'happy path emits a complete, schema-valid report'
# Later refusal cases rewrite DIENE_CORE_REPORT with their own Fail evidence,
# so keep the passing report for the assertions that need one.
pass_report=$scratch/pass-report.json
cp -- "$DIENE_CORE_REPORT" "$pass_report"

grep -Fq -- 'env up --profile ditto --build-mode build-local --artifact' "$DIENE_TEST_PLS_LOG" ||
  fail 'env up was called without the mandatory --artifact'
ok 'env up carries the mandatory --artifact'
grep -Fq -- 'env down --profile ditto' "$DIENE_TEST_PLS_LOG" || fail 'exact teardown was not driven'
ok 'exact teardown is driven through the ratified down'
grep -Fq 'host-policy apply' "$DIENE_TEST_PLS_LOG" || fail 'host policy was never applied'
grep -Fq 'host-policy verify' "$DIENE_TEST_PLS_LOG" ||
  fail 'the posture was never re-attested from the host side'
grep -Fq 'host-policy request-release' "$DIENE_TEST_PLS_LOG" ||
  fail 'no deferred cleanup was requested'
# A job that knows its own receipt must not be able to delete the enforcement
# containing it, so the job side never invokes a real release verb.
! grep -Eq 'host-policy .release' "$DIENE_TEST_PLS_LOG" ||
  fail 'the job invoked a destructive host-policy release'
! grep -Fq 'diene_host_policy_release' ./scripts/ci/environment-lib.sh ||
  fail 'a job-side destructive release verb still exists'
ok 'the job requests deferred cleanup and cannot dissolve its own enforcement'

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
leak_staging=$scratch/leak-staging
mkdir -p "$leak_staging"
for surface in stdout stderr argv environ; do : >"$leak_staging/$surface"; done

# An uncaptured surface can never be reported as scanned: runtime output that
# already streamed to the live log cannot be suppressed retroactively.
DIENE_LEAK_CANARY=leaky-canary-token DIENE_EVIDENCE_STAGING='' \
  expect_refusal EvidenceLeakageInterfaceUnavailable ./scripts/ci/environment-report.sh \
  --kind core --input "$DIENE_CORE_REPORT" --output "$scratch/unstaged.json"
[[ ! -e $scratch/unstaged.json ]] || fail 'an unstaged report survived'

rm -f "$leak_staging/stderr"
DIENE_LEAK_CANARY=leaky-canary-token DIENE_EVIDENCE_STAGING="$leak_staging" \
  expect_refusal EvidenceLeakageInterfaceUnavailable ./scripts/ci/environment-report.sh \
  --kind core --input "$DIENE_CORE_REPORT" --output "$scratch/partial.json"
: >"$leak_staging/stderr"
ok 'a partially captured surface set refuses instead of claiming a scan'

# One negative per surface, and a leak printed by a child command.
jq '.evidence.egressCanary.reasonCode = "leaky-canary-token"' "$DIENE_CORE_REPORT" >"$leak_raw"
DIENE_LEAK_CANARY=leaky-canary-token DIENE_EVIDENCE_STAGING="$leak_staging" \
  expect_refusal EvidenceLeakDetected ./scripts/ci/environment-report.sh \
  --kind core --input "$leak_raw" --output "$scratch/leak.json"
[[ ! -e $scratch/leak.json ]] || fail 'a leaking report survived'
ok 'a positive canary in the report suppresses the artifact'

for surface in stdout stderr argv environ; do
  : >"$leak_staging/$surface"
  # A child command printing the tracer is caught because its output was
  # staged rather than streamed straight to the published log.
  printf 'child said %s\n' leaky-canary-token >"$leak_staging/$surface"
  DIENE_LEAK_CANARY=leaky-canary-token DIENE_EVIDENCE_STAGING="$leak_staging" \
    ./scripts/ci/environment-report.sh --kind core --input "$DIENE_CORE_REPORT" \
    --output "$scratch/leak-$surface.json" >/dev/null 2>&1 &&
    fail "a canary on the $surface surface was not detected"
  [[ ! -e $scratch/leak-$surface.json ]] || fail "a report leaking via $surface survived"
  : >"$leak_staging/$surface"
done
ok 'a canary on stdout, stderr, argv or environ suppresses the artifact'

for encoded in \
  "$(printf '%s' leaky-canary-token | base64 | tr -d '\n')" \
  "$(direnv_unused=1 jq -rn '"leaky-canary-token" | @uri')" \
  "$(printf '%s' leaky-canary-token | base64 | tr -d '\n' | base64 | tr -d '\n')"; do
  printf '%s\n' "$encoded" >"$leak_staging/stdout"
  DIENE_LEAK_CANARY=leaky-canary-token DIENE_EVIDENCE_STAGING="$leak_staging" \
    ./scripts/ci/environment-report.sh --kind core --input "$DIENE_CORE_REPORT" \
    --output "$scratch/leak-enc.json" >/dev/null 2>&1 &&
    fail 'an encoded canary was not detected'
  : >"$leak_staging/stdout"
done
ok 'base64, URL-encoded and kubeconfig-embedded encodings are all detected'

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

grep -Fq 'host-policy request-release' "$DIENE_TEST_PLS_LOG" ||
  fail 'a cancelled run never requested deferred cleanup of its egress posture'
ok 'cancellation inside env up still requests deferred cleanup of the posture'

# The receipt was written before the mutation, so the cancelled run is
# recoverable by owner tuple and its debt is visible rather than silent.
sig_receipt=$(find "$sig_temp/diene-receipts" -name '*.json' -print -quit 2>/dev/null || true)
[[ -n $sig_receipt ]] || fail 'a cancelled run left no receipt to sweep'
jq -e '.owner.allocationKey == "r12345-w8001-a1-lditto-build-local" and .cleanup.outcome != "Pass"' \
  "$sig_receipt" >/dev/null || fail 'the cancelled run receipt is not exact or was falsely marked destroyed'
ok 'a cancelled run leaves an exact, lane-scoped receipt carrying visible debt'

printf '== enforcement boundary is host-owned, not job-owned ==\n'

# Without a root-owned broker the lane refuses. A table this job installs in
# its own namespace is a cooperative setting it can flush, not a boundary.
: >"$DIENE_TEST_PLS_LOG"
DIENE_HOST_POLICY_BROKER_BIN=/nonexistent/diene-host-policy-broker \
  expect_refusal HostPolicyInterfaceUnavailable ./scripts/ci/environment-k3d-run.sh
[[ ! -s $DIENE_TEST_PLS_LOG ]] || fail 'a lane without an enforcement boundary still mutated the substrate'
ok 'no host-owned broker means the lane refuses before any mutation'

# The job holds CAP_NET_ADMIN, so it can flush any table it can see. The
# posture must still be attested from the host side afterwards.
if command -v nft >/dev/null 2>&1; then
  nft delete table inet diene_ci_egress 2>/dev/null || true
  nft flush ruleset 2>/dev/null || true
fi
: >"$DIENE_TEST_PLS_LOG"
DIENE_TEST_POSTURE_BROKEN=1 DIENE_CORE_REPORT=$scratch/broken-posture.json \
  ./scripts/ci/environment-k3d-run.sh >/dev/null 2>&1 &&
  fail 'a lane whose egress posture was not sustained still went green'
jq -e '.outcome == "Fail" and .evidence.egressCanary.outcome == "Fail" and
       .evidence.egressCanary.reasonCode == "PostureNotSustainedForLaneLifetime"' \
  "$scratch/broken-posture.json" >/dev/null ||
  fail 'a broken posture was not recorded as a failed egress canary'
ok 'a posture the host cannot attest fails the lane, whatever the job did to its own tables'

printf '== mandatory lane proofs are not optional coverage ==\n'

# target-pull obligations are required results, so a missing interface refuses.
write_subject "$(jq -nc --arg attest "$attest" --arg workflowRef "$DIENE_BASE_WORKFLOW_REF" \
  '{predicateType:"https://slsa.dev/provenance/v1",provenanceRef:"https://example/prov",
    attestationDigest:$attest,workflowRef:$workflowRef,runId:"8001",runAttempt:"1",
    pullIdentity:"ghcr-reader-identity"}')"
: >"$DIENE_TEST_PLS_LOG"
DIENE_LANE=ditto-target-pull DIENE_PULL_PROOF_BIN=/nonexistent/pull-proof \
  DIENE_ARTIFACT_ATTESTATION_DIGEST="$attest" DIENE_ARTIFACT_PROVENANCE_REF="https://example/prov" \
  expect_refusal RequiredCoverageUnavailable ./scripts/ci/environment-k3d-run.sh
! grep -Fq 'env up' "$DIENE_TEST_PLS_LOG" ||
  fail 'target-pull mutated the substrate without its required proofs'
write_subject

# Absol signature verification and exact-set equality are mandatory too.
: >"$DIENE_TEST_PLS_LOG"
DIENE_LANE=absol DIENE_CLOSURE_VERIFY_BIN=/nonexistent/closure-verify \
  DIENE_CLOSURE_DIGEST="sha256:$(printf c1 | sha256sum | cut -d' ' -f1)" \
  DIENE_CLOSURE_SIGNATURE_BUNDLE_DIGEST="sha256:$(printf c2 | sha256sum | cut -d' ' -f1)" \
  DIENE_CLOSURE_TRUST_ROOT_DIGEST="sha256:$(printf c3 | sha256sum | cut -d' ' -f1)" \
  DIENE_CLOSURE_BUNDLE_REF="https://example/closure/$GITHUB_SHA.tar" \
  expect_refusal ClosureAttestationInterfaceUnavailable ./scripts/ci/environment-k3d-run.sh
! grep -Fq 'env up' "$DIENE_TEST_PLS_LOG" ||
  fail 'Absol mutated the substrate without closure verification'
ok 'target-pull and Absol obligations refuse rather than becoming optional coverage'

# A passing report may not carry a load-bearing obligation as unavailable.
# Asserted against the schema directly, so the rule itself is under test.
validator=${DIENE_SCHEMA_VALIDATOR_BIN:-check-jsonschema}
schema_dir=$work/schemas/ci
"$validator" --base-uri "file://$schema_dir/" \
  --schemafile "$schema_dir/diene-environment-report-v1.schema.json" "$pass_report" >/dev/null ||
  fail 'the happy-path report is not schema-valid to begin with'
jq -e '.outcome == "Pass"' "$pass_report" >/dev/null || fail 'the retained report is not a passing one'
for obligation in closure-exact-set-equality artifact-evict-repull artifact-credential-removal; do
  jq --arg id "$obligation" \
    '.coverage += [{id:$id,outcome:"Unavailable",reasonCode:"InterfaceUnavailable",required:false}]' \
    "$pass_report" >"$scratch/smuggled.json"
  if "$validator" --base-uri "file://$schema_dir/" \
    --schemafile "$schema_dir/diene-environment-report-v1.schema.json" \
    "$scratch/smuggled.json" >/dev/null 2>&1; then
    fail "a Pass report smuggled $obligation in as unavailable coverage"
  fi
done
ok 'a Pass report cannot smuggle a load-bearing obligation in as unavailable coverage'

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
