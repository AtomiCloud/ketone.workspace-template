#!/usr/bin/env bash
# Report finaliser and leakage scanner.
#
# Every report is schema-validated on the way in and on the way out, so a
# malformed or namespace-crossing document can never be published. The leakage
# canary is mandatory and fails closed: an absent canary, an absent search
# tool, or a positive finding all refuse and suppress the artifact rather than
# publishing unscanned evidence.
set -euo pipefail
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$script_dir/environment-lib.sh"

kind=
input=
output=
while (($#)); do
  case $1 in
    --kind)
      kind=${2:-}
      shift 2
      ;;
    --input)
      input=${2:-}
      shift 2
      ;;
    --output)
      output=${2:-}
      shift 2
      ;;
    *) diene_die InputContractInvalid "unknown report argument $1" ;;
  esac
done
[[ -f $input && -n $output ]] || diene_die InputContractInvalid 'report input/output required'
diene_require_command jq
diene_require_command grep
diene_require_command base64
diene_require_command sha256sum

case $kind in
  core)
    jq -e '.apiVersion == "diene.atomi.cloud/ci-environment-report/v1" and
           (has("vendorOutcome") | not) and (has("vendorOutcomes") | not) and (has("actionId") | not)' \
      "$input" >/dev/null || diene_die ReportNamespaceViolation 'core report shape mismatch'
    schema=diene-environment-report-v1.schema.json
    ;;
  vendor)
    jq -e '.apiVersion == "diene.atomi.cloud/ci-vendor-report/v1" and
           (has("journeys") | not) and (has("readiness") | not) and (has("coverage") | not)' \
      "$input" >/dev/null || diene_die ReportNamespaceViolation 'vendor report shape mismatch'
    schema=diene-vendor-report-v1.schema.json
    ;;
  profile)
    jq -e '.apiVersion == "diene.atomi.cloud/ci-profile-report/v1"' "$input" >/dev/null ||
      diene_die ReportNamespaceViolation 'profile report shape mismatch'
    schema=diene-profile-report-v1.schema.json
    ;;
  *) diene_die ReportNamespaceViolation "unknown report kind $kind" ;;
esac

# ---------------------------------------------------------------------------
# Leakage scan. Mandatory for every runtime report; the runtime-free profile
# report holds no runtime evidence and is exempt by declaration, not by
# accident.
# ---------------------------------------------------------------------------

encodings=()
scanned=()

scan_surfaces() {
  local canary=$1
  shift
  local -a needles=()
  local encoded url_encoded json_escaped newline_normalized kubeconfig_embedded
  encoded=$(printf '%s' "$canary" | base64 | tr -d '\n')
  url_encoded=$(jq -rn --arg value "$canary" '$value | @uri')
  json_escaped=$(jq -rn --arg value "$canary" '$value | tojson | .[1:-1]')
  newline_normalized=$(printf '%s' "$canary" | tr '\n' ' ')
  kubeconfig_embedded=$(printf '%s' "$encoded" | base64 | tr -d '\n')
  needles=("$canary" "$encoded" "$url_encoded" "$json_escaped" "$newline_normalized" "$kubeconfig_embedded")
  encodings=(raw base64 url-encoded json-escaped newline-normalized kubeconfig-embedded)

  local needle target
  for target in "$@"; do
    [[ -e $target ]] || continue
    scanned+=("$target")
    for needle in "${needles[@]}"; do
      [[ -n $needle ]] || continue
      if grep -rFq -- "$needle" "$target" 2>/dev/null; then
        return 1
      fi
    done
  done
  return 0
}

leak_outcome=Pass
leak_reason=NoCanaryFound
if [[ $kind == profile ]]; then
  encodings=(raw base64 url-encoded json-escaped newline-normalized kubeconfig-embedded)
  scanned=("$input")
  leak_reason=RuntimeFreeReportNoSecretSurface
else
  canary=${DIENE_LEAK_CANARY:-}
  [[ -n $canary ]] ||
    diene_die EvidenceLeakDetected 'DIENE_LEAK_CANARY is mandatory for runtime reports; refusing to publish unscanned evidence'

  # Every required surface must have actually been captured. Runtime output
  # streamed straight to the GitHub log is already published by the time any
  # grep runs, so a lane that did not route stdout/stderr into mode-0600
  # staging cannot claim a scan happened at all.
  staging=${DIENE_EVIDENCE_STAGING:-}
  [[ -n $staging && -d $staging ]] ||
    diene_die EvidenceLeakageInterfaceUnavailable \
      'no mode-0600 evidence staging directory; runtime stdout/stderr was published unscanned and cannot be suppressed retroactively'
  for required in stdout stderr argv environ; do
    [[ -e "$staging/$required" ]] ||
      diene_die EvidenceLeakageInterfaceUnavailable \
        "the $required surface was never captured; leakageScan cannot be claimed over it"
  done

  proof_bundle_dir=${DIENE_PROOF_BUNDLE_DIR:-}
  [[ -n $proof_bundle_dir && -d $proof_bundle_dir && ! -L $proof_bundle_dir ]] ||
    diene_die EvidenceLeakageInterfaceUnavailable \
      'the final outer proof-bundle directory is absent; a guest-only scan cannot authorize publication'

  # The outer directory is first and mandatory: it contains collected guest
  # proof, create metadata, lifecycle receipts, checkpoint chain and the raw
  # final report. Scanning only a guest report would miss collection-time or
  # orchestrator-time leaks.
  surfaces=("$proof_bundle_dir" "$input" "$staging")
  [[ -z ${RUNNER_TEMP:-} ]] || surfaces+=("$RUNNER_TEMP")
  [[ -z ${GITHUB_WORKSPACE:-} || ! -d ${GITHUB_WORKSPACE:-} ]] || surfaces+=("$GITHUB_WORKSPACE")
  [[ -z ${GITHUB_ENV:-} || ! -f ${GITHUB_ENV:-} ]] || surfaces+=("$GITHUB_ENV")
  [[ -z ${GITHUB_OUTPUT:-} || ! -f ${GITHUB_OUTPUT:-} ]] || surfaces+=("$GITHUB_OUTPUT")
  [[ -z ${GITHUB_STEP_SUMMARY:-} || ! -f ${GITHUB_STEP_SUMMARY:-} ]] || surfaces+=("$GITHUB_STEP_SUMMARY")
  [[ -z ${DIENE_CACHE_DIR:-} || ! -d ${DIENE_CACHE_DIR:-} ]] || surfaces+=("$DIENE_CACHE_DIR")
  if ! scan_surfaces "$canary" "${surfaces[@]}"; then
    leak_outcome=Fail
    leak_reason=CanaryFoundInEvidence
  fi
fi

# ---------------------------------------------------------------------------
# Finalise. The scan verdict is written into the report itself, so a reader
# never has to assume a scan happened.
# ---------------------------------------------------------------------------

staged=$(mktemp "${RUNNER_TEMP:-/tmp}/diene-report.XXXXXX")
if [[ $kind == profile ]]; then
  jq -S . "$input" >"$staged"
else
  jq -S \
    --arg outcome "$leak_outcome" --arg reason "$leak_reason" \
    --argjson encodings "$(printf '%s\n' "${encodings[@]}" | jq -R . | jq -sc .)" \
    --argjson scanned "$(printf '%s\n' "${scanned[@]}" | jq -R . | jq -sc .)" \
    '.evidence.leakageScan = {outcome: $outcome, reasonCode: $reason, encodings: $encodings, scannedPaths: $scanned}' \
    "$input" >"$staged"
fi
chmod 0600 "$staged"
diene_schema_validate "$schema" "$staged" "$kind report"

if [[ $leak_outcome != Pass ]]; then
  rm -f -- "$staged"
  rm -f -- "$output"
  diene_die EvidenceLeakDetected 'leakage canary found in an evidence surface; artifact suppressed'
fi

install -d -m 0700 "$(dirname -- "$output")"
mv -- "$staged" "$output"
chmod 0600 "$output"
digest=$(sha256sum "$output" | awk '{print $1}')
printf '%s_report_digest=sha256:%s\n' "$kind" "$digest" >>"${GITHUB_OUTPUT:-/dev/null}"
