#!/usr/bin/env bash
# Runtime-free profile, corpus and parity gate. It mutates no cluster and
# needs no credential.
#
# EXTERNAL BLOCKER: goals/garden-k3d-profiles.md §2 ratifies no runtime-free
# executable render. `pls env switch --profile <p> --build-mode <m>` is the
# only ratified command that validates a profile/mode pair without mutating an
# active environment, so it carries the build-mode matrix here. The full
# executable render of the Garden graph, dependency realizations, exposure
# plans, readiness leaves and one-writer inventory has no ratified command:
# rather than invent `pls env render`, a repository that has opted into the
# environment lock refuses ProfileRenderInterfaceUnavailable until Garden
# publishes that interface. Point DIENE_PROFILE_RENDER_BIN at it once it
# exists and this gate becomes executable with no template change.
set -euo pipefail
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$script_dir/environment-lib.sh"

profile_renderer() {
  local renderer=${DIENE_PROFILE_RENDER_BIN:-}
  [[ -n $renderer ]] ||
    diene_die ProfileRenderInterfaceUnavailable 'Garden ratifies no runtime-free executable render command'
  command -v -- "$renderer" >/dev/null 2>&1 ||
    diene_die ProfileRenderInterfaceUnavailable 'configured profile renderer is absent or not executable'
  printf '%s\n' "$renderer"
}

if [[ ${1:-} == --validate-inputs ]]; then
  diene_validate_inputs
  exit 0
fi

# Pre-SIT prerequisites. This is deliberately runtime-free and is invoked both
# by the workflow contract job and again by the lifecycle orchestrator before
# `nsc create`. A missing producer, invalid selected declaration, malformed
# production fixture, bad Promotion/Freight object, or non-canonical duration
# refuses before Namespace authority mutates anything.
if [[ ${1:-} == --validate-prerequisites ]]; then
  diene_require_command jq
  diene_require_command "${DIENE_SCHEMA_VALIDATOR_BIN:-check-jsonschema}"
  producer=${DIENE_ARTIFACT_PRODUCER:-.diene/ci/artifact-producer.sh}
  [[ -x $producer ]] ||
    diene_die ArtifactProducerUnavailable 'no repository-owned artifact producer; refusing before nsc create'
  [[ ${DIENE_NSC_DURATION:-2h} == 2h ]] ||
    diene_die ProductionFixtureInvalid 'production SIT duration is exactly 2h'
  [[ ${DIENE_PRE_SIT_NEGATIVE_CANARY:-0} == 0 ]] ||
    diene_die ProductionFixtureInvalid 'the pre-SIT negative canary was intentionally activated'

  if [[ ${DIENE_LANE:-} == ditto-vendor ]]; then
    [[ -f ${DIENE_VENDOR_MANIFEST} ]] || diene_die InputContractInvalid 'vendor manifest missing'
    diene_schema_validate diene-vendors-v1.schema.json "$DIENE_VENDOR_MANIFEST" 'vendor manifest'
    jq -e --arg id "${DIENE_ACTION_ID:?}" '[.actions[] | select(.actionId == $id)] | length == 1' \
      "$DIENE_VENDOR_MANIFEST" >/dev/null ||
      diene_die InputContractInvalid 'vendor action is not declared exactly once'
  else
    journeys=${DIENE_JOURNEY_MANIFEST:-}
    [[ $journeys == .diene/ci/journeys.v1.yaml && -f $journeys ]] ||
      diene_die InputContractInvalid 'selected journey manifest is absent or non-canonical'
    diene_select_journeys "$journeys"
  fi

  fixture_root=${DIENE_PRE_SIT_FIXTURE_ROOT:-.diene/ci/fixtures}
  if [[ -d $fixture_root ]]; then
    while IFS= read -r -d '' fixture; do
      fixture_json=$fixture
      converted=
      if ! jq empty "$fixture" >/dev/null 2>&1; then
        diene_require_command yq
        converted=$(mktemp "${RUNNER_TEMP:-/tmp}/diene-fixture.XXXXXX")
        yq -o=json '.' "$fixture" >"$converted" || {
          rm -f -- "$converted"
          diene_die ProductionFixtureInvalid "$fixture is not valid YAML/JSON"
        }
        fixture_json=$converted
      fi
      jq -e '
        ([.. | objects | .duration? // empty] |
          all(type == "string" and test("^[1-9][0-9]*(s|m|h|d)$"))) and
        ([.. | objects | select(.kind? == "Promotion" or .kind? == "Freight")] |
          all((.apiVersion | type == "string" and length > 0) and
              (.metadata.name | type == "string" and length > 0)))
      ' "$fixture_json" >/dev/null || {
        [[ -z $converted ]] || rm -f -- "$converted"
        diene_die ProductionFixtureInvalid \
          "$fixture carries an invalid Promotion/Freight object or duration spelling"
      }
      [[ -z $converted ]] || rm -f -- "$converted"
    done < <(find "$fixture_root" -type f \( -name 'manifest.yaml' -o -name 'manifest.yml' -o -name 'manifest.json' \) -print0)
  fi

  selected_manifest=${DIENE_VENDOR_MANIFEST:-${DIENE_JOURNEY_MANIFEST:-}}
  if [[ -f $selected_manifest ]]; then
    while IFS=$'\t' read -r pack_id pack_digest; do
      [[ -n $pack_id ]] || continue
      pack_path="$fixture_root/$pack_id/manifest.yaml"
      [[ ! -f $pack_path ]] || [[ $(diene_file_digest "$pack_path") == "$pack_digest" ]] ||
        diene_die ProductionFixtureInvalid "present fixture $pack_id does not match its immutable digest"
    done < <(jq -r '
      if has("journeys") then .journeys[].fixturePack
      else .actions[].fixturePack end | [.id,.digest] | @tsv
    ' "$selected_manifest")
  fi

  printf 'PreSitContractAccepted\n'
  exit 0
fi

# Validate one same-run artifact subject emitted by the repository-owned
# producer. The subject is never a checked-in file: its producer run, attempt
# and workflow ref must bind the run that is about to consume it, so a
# committed declaration cannot satisfy the handoff.
if [[ ${1:-} == --validate-subject ]]; then
  subject=${2:?subject path required}
  diene_require_command jq
  diene_require_command "${DIENE_SCHEMA_VALIDATOR_BIN:-check-jsonschema}"
  [[ -f $subject ]] || diene_die ArtifactProducerUnavailable 'the producer emitted no artifact subject'
  diene_schema_validate diene-artifact-subject-v1.schema.json "$subject" 'artifact subject'
  jq -e \
    --arg sha "${GITHUB_SHA:?}" \
    --arg runId "${GITHUB_RUN_ID:?}" \
    --arg runAttempt "${GITHUB_RUN_ATTEMPT:?}" \
    --arg workflowRef "${DIENE_BASE_WORKFLOW_REF:?}" '
      .sourceSha == $sha and
      .artifact.producer.runId == $runId and
      .artifact.producer.runAttempt == $runAttempt and
      .artifact.producer.workflowRef == $workflowRef
    ' "$subject" >/dev/null ||
    diene_die UntrustedSubject 'artifact subject is not a same-run output bound to this workflow, run and attempt'
  if jq -e 'has("provenance")' "$subject" >/dev/null; then
    jq -e \
      --arg runId "${GITHUB_RUN_ID}" --arg runAttempt "${GITHUB_RUN_ATTEMPT}" \
      --arg workflowRef "${DIENE_BASE_WORKFLOW_REF}" '
        .provenance.runId == $runId and .provenance.runAttempt == $runAttempt and
        .provenance.workflowRef == $workflowRef
      ' "$subject" >/dev/null ||
      diene_die UntrustedSubject 'attestation provenance does not bind this workflow, run and attempt'
  fi
  # A repository whose journeys declare the Absol lane must also declare a
  # complete signed closure. Omitting it would silently drop environment-absol
  # from a protected build, so it refuses here, runtime-free, instead.
  journeys=${DIENE_JOURNEY_MANIFEST:-.diene/ci/journeys.v1.yaml}
  if [[ -f $journeys ]] && jq -e 'any(.journeys[].appliesTo[]; .lane == "absol")' "$journeys" >/dev/null; then
    jq -e '
      (.closure | type == "object") and
      (.closure.bundleRef | type == "string") and
      (.closure.digest | type == "string") and
      (.closure.signatureBundleDigest | type == "string") and
      (.closure.trustRootDigest | type == "string")
    ' "$subject" >/dev/null ||
      diene_die RequiredCoverageUnavailable 'journeys declare the Absol lane but the subject carries no complete signed closure'
  fi

  printf 'ArtifactSubjectAccepted\n'
  exit 0
fi

if [[ ${1:-} == --render-profile ]]; then
  profile=${2:-}
  case $profile in
    castform | eevee) diene_die PreviewIdentityUnavailable "$profile executable rendering is outside this node" ;;
    lapras | ditto | rotom | absol) ;;
    *) diene_die InputContractInvalid "unknown profile $profile" ;;
  esac
  renderer=$(profile_renderer)
  "$renderer" --profile "$profile" ||
    diene_die ProfileRenderInterfaceUnavailable "$profile executable renderer failed"
  exit 0
fi

diene_require_command jq
diene_require_command "${DIENE_SCHEMA_VALIDATOR_BIN:-check-jsonschema}"

lock=${DIENE_ENVIRONMENT_LOCK:-.diene/ci/environment-lock.v1.json}
report=${DIENE_PROFILE_REPORT:-${RUNNER_TEMP:-/tmp}/diene-profile-contract.json}
raw=$(mktemp "${RUNNER_TEMP:-/tmp}/diene-profile-raw.XXXXXX")
render_dir=
cleanup_profile_temps() {
  rm -f -- "$raw"
  if [[ -n $render_dir ]]; then
    chmod -R u+rwX "$render_dir" 2>/dev/null || true
    rm -r -- "$render_dir"
  fi
}
trap cleanup_profile_temps EXIT

emit() {
  "$script_dir/environment-report.sh" --kind profile --input "$raw" --output "$report"
  printf 'profile_report=%s\n' "$report" >>"${GITHUB_OUTPUT:-/dev/null}"
}

# A repository that declares no environment lock has not opted in. That is
# explicit NotApplicable/NoDeclaration, never an implied pass.
if [[ ! -e $lock && ! -L $lock ]]; then
  jq -n '{
    apiVersion: "diene.atomi.cloud/ci-profile-report/v1",
    outcome: "NotApplicable", reasonCode: "NoDeclaration",
    renderedProfiles: [], validatedProfiles: [],
    staticContract: {
      profileSet: {outcome: "NotApplicable", reasonCode: "NoDeclaration"},
      substrateParity: {outcome: "NotApplicable", reasonCode: "NoDeclaration"},
      retiredNames: {outcome: "NotApplicable", reasonCode: "NoDeclaration"},
      consumerPinAliases: {outcome: "NotApplicable", reasonCode: "NoDeclaration"},
      oneWriter: {outcome: "NotApplicable", reasonCode: "NoDeclaration"},
      buildModeMatrix: {outcome: "NotApplicable", reasonCode: "NoDeclaration"}
    }
  }' >"$raw"
  emit
  exit 0
fi

[[ -f $lock && ! -L $lock ]] ||
  diene_die InputContractInvalid 'environment lock must be a regular file'
jq empty "$lock" >/dev/null 2>&1 ||
  diene_die PreviewManifestSchemaMismatch 'environment lock is not valid JSON'

lock_digest=$(diene_file_digest "$lock")

# --- static corpus gates over the repository-owned lock ---------------------

jq -e '[.profiles | keys[]] | all(. != "porygon")' "$lock" >/dev/null ||
  diene_die PreviewManifestSchemaMismatch 'retired profile identity porygon found'

jq -e '
  . as $root |
  .apiVersion == "diene.atomi.cloud/environment-lock/v1" and
  ((.profiles | keys | sort) == ["absol","castform","ditto","eevee","lapras","rotom"])
' "$lock" >/dev/null || diene_die PreviewManifestSchemaMismatch 'profile set is not the exact six-name set'

jq -e '
  . as $root |
  (["lapras","ditto","rotom","absol"] | all(. as $p | $root.profiles[$p].substrate == "k3d")) and
  (["eevee","castform"] | all(. as $p | $root.profiles[$p].substrate == "entei-vcluster"))
' "$lock" >/dev/null || diene_die PreviewManifestSchemaMismatch 'substrate parity mismatch'

jq -e '
  ([.. | objects | keys[]] | all(. != "ref" and . != "operatorId" and . != "versionPin" and . != "commitPin")) and
  ([.. | objects | select(has("kind"))] | all(.kind == "operator" and ((keys | sort) == ["kind","version"])))
' "$lock" >/dev/null || diene_die PreviewManifestSchemaMismatch 'consumer pin alias or operator shape found'

jq -e '
  (.previewManifest.schemaVersion == "preview-manifest/v1") and
  (.previewManifest.schemaDigest | test("^sha256:[0-9a-f]{64}$")) and
  (.previewManifest.wordListVersion | type == "string")
' "$lock" >/dev/null || diene_die PreviewManifestSchemaMismatch 'imported preview-manifest lock entry is absent or aliased'

# Each mutable object and Secret has exactly one declared writer.
jq -e '
  [.. | objects | select(has("soleWriter")) | .soleWriter | (.objects // []) + (.secrets // []) | .[]] as $owned |
  ($owned | length) == ($owned | unique | length)
' "$lock" >/dev/null || diene_die PreviewManifestSchemaMismatch 'one-writer ownership is violated'

# --- ratified runtime-free profile/mode validation --------------------------

pls_bin=${DIENE_PLS_BIN:-pls}
diene_require_command "$pls_bin"
# Ditto permits only build-local|target-pull; Absol only closure-backed
# build-local. Switching validates the pair and never mutates.
"$pls_bin" env switch --profile ditto --build-mode build-local ||
  diene_die PreviewManifestSchemaMismatch 'Ditto build-local profile/mode pair was refused'
"$pls_bin" env switch --profile ditto --build-mode target-pull ||
  diene_die PreviewManifestSchemaMismatch 'Ditto target-pull profile/mode pair was refused'
"$pls_bin" env switch --profile absol --build-mode build-local ||
  diene_die PreviewManifestSchemaMismatch 'Absol build-local profile/mode pair was refused'
if "$pls_bin" env switch --profile absol --build-mode target-pull 2>/dev/null; then
  diene_die PreviewManifestSchemaMismatch 'Absol accepted a non closure-backed build mode'
fi

# --- executable render: refused until Garden ratifies an interface ----------

rendered='[]'
render_outcome=Unavailable
render_reason=ProfileRenderInterfaceUnavailable
if [[ -n ${DIENE_PROFILE_RENDER_BIN:-} ]]; then
  renderer=$(profile_renderer)
  render_dir=$(mktemp -d "${RUNNER_TEMP:-/tmp}/diene-profile.XXXXXX")
  for profile in lapras ditto rotom absol; do
    "$renderer" --profile "$profile" >"$render_dir/$profile.json" ||
      diene_die ProfileRenderInterfaceUnavailable "$profile executable renderer failed"
    jq -e --arg profile "$profile" '.profile == $profile and .substrate == "k3d"' "$render_dir/$profile.json" >/dev/null ||
      diene_die ProfileRenderMismatch "$profile did not render the local k3d contract"
  done
  rendered='["lapras","ditto","rotom","absol"]'
  render_outcome=Pass
  render_reason=ContractSatisfied
fi

overall_outcome=Pass
overall_reason=ContractSatisfied
if [[ $render_outcome != Pass ]]; then
  overall_outcome=Fail
  overall_reason=ProfileRenderInterfaceUnavailable
fi

jq -n \
  --arg repositoryRevision "${GITHUB_SHA:-}" \
  --arg schemaVersion "$(jq -r '.previewManifest.schemaVersion' "$lock")" \
  --arg schemaDigest "$(jq -r '.previewManifest.schemaDigest' "$lock")" \
  --arg wordListVersion "$(jq -r '.previewManifest.wordListVersion' "$lock")" \
  --arg lockDigest "$lock_digest" \
  --arg outcome "$overall_outcome" --arg reason "$overall_reason" \
  --arg renderReason "$render_reason" \
  --argjson rendered "$rendered" \
  --arg renderOutcome "$render_outcome" \
  '{
    apiVersion: "diene.atomi.cloud/ci-profile-report/v1",
    outcome: $outcome, reasonCode: $reason,
    renderedProfiles: $rendered,
    validatedProfiles: ["eevee","castform"],
    previewManifest: {schemaVersion: $schemaVersion, schemaDigest: $schemaDigest, wordListVersion: $wordListVersion},
    staticContract: {
      profileSet: {outcome: "Pass", reasonCode: "ExactSixNameSet"},
      substrateParity: {outcome: "Pass", reasonCode: "LocalK3dHostedVcluster"},
      retiredNames: {outcome: "Pass", reasonCode: "NoRetiredIdentity"},
      consumerPinAliases: {outcome: "Pass", reasonCode: "NoAliasFound"},
      oneWriter: {outcome: "Pass", reasonCode: "SingleWriterPerObject"},
      buildModeMatrix: {outcome: "Pass", reasonCode: "ProfileModePairsValidated"}
    },
    castformExecutable: {outcome: "Unavailable", reasonCode: "PreviewIdentityUnavailable"},
    eeveeExecutable: {outcome: "Unavailable", reasonCode: "PreviewIdentityUnavailable"},
    localExecutableRender: {outcome: $renderOutcome, reasonCode: $renderReason},
    toolingDigests: {environmentLockDigest: $lockDigest}
  }
  | (if $repositoryRevision == "" then . else . + {repositoryRevision: $repositoryRevision} end)' \
  >"$raw"
emit

[[ $overall_outcome == Pass ]] ||
  diene_die ProfileRenderInterfaceUnavailable 'no ratified runtime-free executable render; set DIENE_PROFILE_RENDER_BIN once Garden publishes one'
