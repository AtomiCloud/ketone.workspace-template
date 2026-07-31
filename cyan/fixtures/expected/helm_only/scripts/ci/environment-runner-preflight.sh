#!/usr/bin/env bash
# Runner posture gate. It binds the signed lease to this exact job — not just
# to the run — so one lane can never execute against a lease minted for a
# sibling lane of the same workflow run.
set -euo pipefail
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$script_dir/environment-lib.sh"

diene_require_command jq
diene_require_command stat

# Bootstrap exports the job-visible projection of the signed lease. That
# projection is exactly mode 0440 at the .public.json path; the private lease
# is never readable from a job, so accepting 0400/0600 here would refuse every
# real job.
lease=${DIENE_RUNNER_LEASE_FILE:-/run/diene-runner-lease.v1.public.json}
[[ -f $lease ]] || diene_die RunnerIsolationUnavailable 'signed runner lease projection is absent'
mode=$(stat -c %a "$lease")
[[ $mode == 440 ]] ||
  diene_die RunnerIsolationUnavailable "lease projection mode is $mode, expected the 0440 job-visible projection"

# The deterministic job label is part of the trust tuple. Runtime labels are
# the fixed four image labels plus exactly one job label.
expected_job=${DIENE_EXPECTED_JOB_ID:-}
[[ -n $expected_job ]] || diene_die RunnerIsolationUnavailable 'expected job identity is not declared'
expected_label="diene-job-r${GITHUB_REPOSITORY_ID:-}-w${GITHUB_RUN_ID:-}-a${GITHUB_RUN_ATTEMPT:-}-j${expected_job}"

jq -e \
  --arg repositoryId "${GITHUB_REPOSITORY_ID:-}" \
  --arg repositoryKey "${GITHUB_REPOSITORY:-}" \
  --arg runId "${GITHUB_RUN_ID:-}" \
  --arg runAttempt "${GITHUB_RUN_ATTEMPT:-}" \
  --arg sourceSha "${GITHUB_SHA:-}" \
  --arg jobLabel "$expected_label" '
  .apiVersion == "diene.atomi.cloud/ci-runner-lease/v1" and
  (.repositoryId | tostring) == $repositoryId and .repositoryKey == $repositoryKey and
  (.runId | tostring) == $runId and (.runAttempt | tostring) == $runAttempt and
  .sourceSha == $sourceSha and .state == "Online" and
  (.labels | length == 5) and
  (.labels | index("diene-k3d-isolated-v1") != null) and
  (.labels | index($jobLabel) != null) and
  ([.labels[] | select(startswith("diene-job-"))] | length == 1)
' "$lease" >/dev/null || diene_die RunnerIsolationUnavailable 'runner lease tuple or job label mismatch'

if [[ ${DIENE_PREFLIGHT_HOST_CHECKS:-1} == 1 ]]; then
  for command in uname nproc awk df docker nft unshare; do
    diene_require_command "$command"
  done
  [[ $(uname -s) == Linux ]] || diene_die RunnerIsolationUnavailable 'Linux required'
  [[ $(uname -r) == 6.8* ]] || diene_die RunnerIsolationUnavailable 'Linux 6.8 required'
  [[ $(stat -fc %T /sys/fs/cgroup) == cgroup2fs ]] || diene_die RunnerIsolationUnavailable 'cgroup v2 required'
  (($(nproc) >= 8)) || diene_die RunnerIsolationUnavailable '8 vCPU required'
  (($(awk '/MemTotal/ {print int($2/1024/1024)}' /proc/meminfo) >= 30)) ||
    diene_die RunnerIsolationUnavailable '32 GiB class memory required'
  (($(df --output=avail -B1 "${RUNNER_TEMP:?}" | tail -n 1) >= 100 * 1024 * 1024 * 1024)) ||
    diene_die RunnerIsolationUnavailable '100 GiB free disk required'
  [[ $(docker version --format '{{.Server.Version}}') == 28.3.3 ]] ||
    diene_die RunnerIsolationUnavailable 'Docker pin mismatch'
  [[ -z $(docker ps -aq) && -z $(docker volume ls -q) ]] ||
    diene_die RunnerIsolationUnavailable 'Docker state is not empty'
  # The job identity holds CAP_NET_ADMIN and is explicitly denied
  # CAP_SYS_ADMIN. Prove both directions: network administration must work, and
  # the namespace-creating capabilities must NOT. Requiring `unshare` to
  # succeed would demand CAP_SYS_ADMIN and so contradict the isolation model.
  nft list ruleset >/dev/null ||
    diene_die RunnerIsolationUnavailable 'job identity lacks CAP_NET_ADMIN for host policy'
  if unshare --net true 2>/dev/null; then
    diene_die RunnerIsolationUnavailable 'job identity holds CAP_SYS_ADMIN; isolation is not enforced'
  fi
  if command -v nsenter >/dev/null 2>&1 && nsenter --net=/proc/1/ns/net true 2>/dev/null; then
    diene_die RunnerIsolationUnavailable 'job identity can enter another namespace; isolation is not enforced'
  fi
fi

printf 'RunnerProvisionerReady\n'
