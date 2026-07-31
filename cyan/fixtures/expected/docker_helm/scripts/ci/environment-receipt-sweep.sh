#!/usr/bin/env bash
# Exact-receipt sweeper. It accepts only a receipt whose immutable owner tuple
# matches all four arguments and destroys exactly that run's substrate through
# the ratified `pls env down --profile <p>` against the receipt-bound Garden
# runtime file. Missing ownership fields, multiple matches, a readable-prefix
# match, or an unbound runtime file produce visible cleanup debt and no
# deletion; no selector is ever profile, landscape, prefix or label alone.
#
# It is idempotent: a receipt already marked destroyed is reported and left
# alone, so the always() post-job sweep never issues a second teardown.
set -euo pipefail
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$script_dir/environment-lib.sh"

repository_id=
run_id=
run_attempt=
receipt_id=
while (($#)); do
  case $1 in
    --repository-id)
      repository_id=${2:-}
      shift 2
      ;;
    --run-id)
      run_id=${2:-}
      shift 2
      ;;
    --run-attempt)
      run_attempt=${2:-}
      shift 2
      ;;
    --receipt-id)
      receipt_id=${2:-}
      shift 2
      ;;
    *) diene_die ReceiptOwnershipMismatch "unknown sweep argument $1" ;;
  esac
done
# The interface is exactly the four selectors the goal fixes: repository ID,
# run ID, run attempt, and an explicit opaque receipt ID. Callers derive the
# lane-scoped receipt ID from diene_receipt_id in the shared library so there
# is one formula, but the destructive interface never widens.
[[ $repository_id =~ ^[1-9][0-9]*$ && $run_id =~ ^[1-9][0-9]*$ && $run_attempt =~ ^[1-9][0-9]*$ ]] ||
  diene_die ReceiptOwnershipMismatch 'numeric owner tuple required'
diene_require_safe_id receipt_id "$receipt_id"
diene_require_command jq

receipt_dir=${DIENE_RECEIPT_DIR:-${RUNNER_TEMP:?}/diene-receipts}
[[ -d $receipt_dir ]] || diene_die CleanupDebt 'receipt directory missing'

matches=()
while IFS= read -r -d '' candidate; do
  if jq -e \
    --arg repositoryId "$repository_id" --arg runId "$run_id" \
    --arg runAttempt "$run_attempt" --arg receiptId "$receipt_id" '
      .apiVersion == "diene.atomi.cloud/ci-receipt/v1" and
      (.owner.repositoryId | tostring) == $repositoryId and
      (.owner.runId | tostring) == $runId and
      (.owner.runAttempt | tostring) == $runAttempt and
      .owner.receiptId == $receiptId
    ' "$candidate" >/dev/null 2>&1; then
    matches+=("$candidate")
  fi
done < <(find "$receipt_dir" -maxdepth 1 -type f -name '*.json' -print0)
((${#matches[@]} == 1)) || diene_die CleanupDebt "expected one exact receipt, found ${#matches[@]}"
receipt=${matches[0]}
diene_schema_validate diene-ci-receipt-v1.schema.json "$receipt" 'cleanup receipt'

state=$(jq -r '.cleanup.outcome' "$receipt")
if [[ $state == Pass ]]; then
  printf 'ExactReceiptAlreadyDestroyed: %s\n' "$receipt_id"
  exit 0
fi

profile=$(jq -er '.profile' "$receipt")
runtime_file=$(jq -r '.runtimeFile // empty' "$receipt")
if [[ -z $runtime_file ]]; then
  # No Garden runtime record was ever bound, so nothing authorises deletion.
  # Deleting by profile alone is forbidden; the debt stays visible instead.
  jq '.cleanup = {outcome: "Fail", reasonCode: "RuntimeEvidenceUnavailable",
      debt: ["no Garden runtime record was bound to this receipt; no deletion attempted"]}' \
    "$receipt" | diene_write_json "$receipt"
  diene_die CleanupDebt "receipt $receipt_id has no bound runtime file; refusing a profile-only teardown"
fi

[[ -f $runtime_file ]] || diene_die CleanupDebt 'receipt runtime file missing'
runtime_mode=$(stat -c %a "$runtime_file")
[[ $runtime_mode == 600 ]] || diene_die CleanupDebt "runtime file mode is $runtime_mode"
diene_schema_validate diene-runtime-consumption-v1.schema.json "$runtime_file" 'Garden runtime record'
jq -e \
  --arg repositoryId "$repository_id" --arg profile "$profile" \
  --arg allocationKey "$(jq -r '.owner.allocationKey' "$receipt")" \
  --arg generationKey "$(jq -r '.owner.generationKey' "$receipt")" \
  --arg repositoryKey "$(jq -r '.owner.repositoryKey' "$receipt")" '
    (.owner.repositoryId | tostring) == $repositoryId and
    .owner.repositoryKey == $repositoryKey and
    .owner.allocationKey == $allocationKey and
    .owner.generationKey == $generationKey and
    .profile == $profile
  ' "$runtime_file" >/dev/null ||
  diene_die CleanupDebt 'runtime file owner tuple does not match the receipt'

if DIENE_GARDEN_RUNTIME_FILE=$runtime_file "${DIENE_PLS_BIN:-pls}" env down --profile "$profile"; then
  jq '.cleanup = {outcome: "Pass", reasonCode: "ExactReceiptDestroyed", debt: []}' "$receipt" |
    diene_write_json "$receipt"
  printf 'ExactReceiptDestroyed: %s\n' "$receipt_id"
else
  jq '.cleanup = {outcome: "Fail", reasonCode: "ExactDownFailed",
      debt: ["pls env down did not converge for the receipt-bound runtime file"]}' \
    "$receipt" | diene_write_json "$receipt"
  diene_die CleanupDebt "exact teardown did not converge for $receipt_id"
fi
