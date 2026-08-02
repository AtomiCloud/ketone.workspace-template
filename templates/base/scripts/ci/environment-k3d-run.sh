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
ORCH_NSC_VERSION=
ORCH_NSC_ARTIFACT_DIGEST=
ORCH_NSC_BINARY_DIGEST=
ORCH_PUBLICATION_SAFE=1
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
  if ! diene_archive_is_safe "$archive" evidence; then
    ORCH_PUBLICATION_SAFE=0
    diene_warn EvidenceLeakageInterfaceUnavailable \
      'collected proof archive has an unsafe name, link, device, FIFO, socket, or other special member'
    return "$DIENE_REASON_EXIT"
  fi
  [[ ! -e $target/evidence && ! -L $target/evidence ]] || {
    ORCH_PUBLICATION_SAFE=0
    diene_warn EvidenceLeakageInterfaceUnavailable 'collected evidence target already exists'
    return "$DIENE_REASON_EXIT"
  }
  install -d -m 0700 "$target"
  if ! tar --extract --no-same-owner --no-same-permissions --keep-old-files \
    -f "$archive" -C "$target" || ! diene_tree_is_safe "$target"; then
    ORCH_PUBLICATION_SAFE=0
    diene_warn EvidenceLeakageInterfaceUnavailable \
      'collected proof could not be extracted into a completely scannable regular tree'
    return "$DIENE_REASON_EXIT"
  fi
}

orchestrator_write_remote_archive_validator() {
  local target=${1:?remote archive validator target required}
  cat >"$target" <<'VALIDATOR'
#!/bin/sh
set -eu
archive=${1:?archive required}
target=${2:?target required}
fail() {
  printf '%s\n' "UntrustedSubject: $*" >&2
  exit 64
}
[ -f "$archive" ] && [ ! -L "$archive" ] || fail 'source archive is not a regular file'
listing=$(mktemp "${TMPDIR:-/tmp}/diene-archive-list.XXXXXX") || fail 'cannot allocate archive listing'
types=$(mktemp "${TMPDIR:-/tmp}/diene-archive-types.XXXXXX") || {
  rm -f -- "$listing"
  fail 'cannot allocate archive type listing'
}
paths=$(mktemp "${TMPDIR:-/tmp}/diene-source-paths.XXXXXX") || {
  rm -f -- "$listing" "$types"
  fail 'cannot allocate extracted-tree listing'
}
cleanup() { rm -f -- "$listing" "$types" "$paths"; }
trap cleanup EXIT HUP INT TERM
LC_ALL=C tar -tf "$archive" >"$listing" || fail 'source archive cannot be listed'
LC_ALL=C tar -tvf "$archive" >"$types" || fail 'source archive types cannot be listed'
[ "$(wc -l <"$listing")" -gt 0 ] &&
  [ "$(wc -l <"$listing")" -eq "$(wc -l <"$types")" ] || fail 'source archive listing is ambiguous'
LC_ALL=C awk '
  function unsafe(name, normalized, escaped) {
    escaped = name
    while (match(escaped, /\\[23][0-7][0-7]/))
      escaped = substr(escaped, 1, RSTART - 1) "U" substr(escaped, RSTART + RLENGTH)
    if (escaped ~ /\\/) return 1
    if (name == "" || name ~ /^\// || name ~ /\/\//) return 1
    normalized = name
    sub(/\/$/, "", normalized)
    if (normalized == "" || normalized == "." || normalized ~ /(^|\/)\.\.?(\/|$)/) return 1
    if (seen[normalized]++) return 1
    return 0
  }
  unsafe($0) { bad=1 }
  END { exit bad ? 1 : 0 }
' "$listing" || fail 'source archive contains an unsafe or non-normalized name'
LC_ALL=C awk '
  substr($0, 1, 1) != "-" && substr($0, 1, 1) != "d" { bad=1 }
  END { exit bad ? 1 : 0 }
' "$types" || fail 'source archive contains a link or special member'
[ ! -e "$target" ] && [ ! -L "$target" ] || fail 'source extraction target is not fresh'
install -d -m 0700 "$target"
tar -xf "$archive" -C "$target" || fail 'constrained source extraction failed'
find "$target" -print >"$paths" || fail 'extracted source tree cannot be traversed'
while IFS= read -r path; do
  if [ -L "$path" ]; then
    fail 'extracted source tree contains a link'
  elif [ -f "$path" ]; then
    [ -r "$path" ] || fail 'extracted source tree contains an unreadable file'
  elif [ -d "$path" ]; then
    [ -r "$path" ] && [ -x "$path" ] || fail 'extracted source tree contains an unreadable directory'
  else
    fail 'extracted source tree contains a special object'
  fi
done <"$paths"
cleanup
trap - EXIT HUP INT TERM
VALIDATOR
  chmod 0500 "$target"
}

# One fixed pre-Nix remote program. The tagged shell is verified but remains
# mode 0600 and is never executed; only the independently pinned binary gains
# execute permission. Identity acceptance is deferred to the in-shell
# preflight, which runs before policy or application mutation.
orchestrator_fixed_remote_command() {
  local contract installer_digest installer_bytes payload_digest payload_bytes remote_command
  local guest_nix_stage2
  contract=$(diene_guest_nix_contract) || return $?
  installer_digest=$(jq -er '.installerDigest' <<<"$contract") ||
    diene_die InputContractInvalid 'guest Nix provenance digest is absent from the fixed contract'
  installer_bytes=$(jq -er '.installerBytes' <<<"$contract") ||
    diene_die InputContractInvalid 'guest Nix provenance length is absent from the fixed contract'
  payload_digest=$(jq -er '.payloadDigest' <<<"$contract") ||
    diene_die InputContractInvalid 'guest Nix payload digest is absent from the fixed contract'
  payload_bytes=$(jq -er '.payloadBytes' <<<"$contract") ||
    diene_die InputContractInvalid 'guest Nix payload length is absent from the fixed contract'
  diene_require_digest guest-nix-remote-installer-digest "$installer_digest"
  diene_require_digest guest-nix-remote-payload-digest "$payload_digest"
  [[ $installer_bytes =~ ^[1-9][0-9]*$ && $payload_bytes =~ ^[1-9][0-9]*$ ]] ||
    diene_die InputContractInvalid 'guest Nix remote pin lengths are invalid'

  remote_command=$(cat <<'REMOTE'
set -eu
umask 077
guest_nix_inherited_nix_command=absent
if command -v nix >/dev/null 2>&1; then
  guest_nix_inherited_nix_command=present
fi
GUEST_NIX_PATH=/usr/sbin:/usr/bin:/sbin:/bin
PATH=$GUEST_NIX_PATH
export PATH
LC_ALL=C
export LC_ALL
guest_nix_fail() { printf '%s: %s\n' "$1" "$2" >&2; exit 64; }

# --- BEGIN guest nix environment contract ---
# POSIX env prints NAME=VALUE per line, so an inherited name always begins a
# line. An embedded NIX-shaped line in a value can only over-refuse, which is
# the fail-closed direction; diagnostics intentionally print names, not values.
guest_nix_inherited_nix_names() {
  guest_nix_environment=$(env) || return 1
  printf '%s\n' "$guest_nix_environment" |
    sed -n 's/^\(NIX[A-Za-z0-9_]*\)=.*$/\1/p'
}
guest_nix_require_clean_nix_env() {
  inherited=$(guest_nix_inherited_nix_names) ||
    guest_nix_fail GuestNixInstallerUntrusted \
      'the fixed-path inherited environment could not be enumerated'
  [ -z "$inherited" ] ||
    guest_nix_fail GuestNixInstallerUntrusted \
      "inherited Nix-family environment variables are prohibited: $(printf '%s' "$inherited" | tr '\n' ' ')"
}
guest_nix_require_commands() {
  for guest_nix_cmd in env sed tr id install cd sha256sum chmod wc cat printf uname \
    readlink sort cut tar find awk mktemp rm; do
    command -v "$guest_nix_cmd" >/dev/null 2>&1 ||
      guest_nix_fail GuestNixInstallerUntrusted \
        "a required guest command is absent from the fixed PATH: $guest_nix_cmd"
  done
}
# --- END guest nix environment contract ---

guest_nix_require_commands
guest_nix_require_clean_nix_env
test "$(id -u)" = 0
install -d -m 0700 /run/diene-ci/tmp /run/diene-ci/evidence /run/diene-ci/receipts /run/diene-ci/out
GUEST_NIX_HOME=/run/diene-ci/home
install -d -m 0700 "$GUEST_NIX_HOME" "$GUEST_NIX_HOME/.config"
HOME=$GUEST_NIX_HOME
XDG_CONFIG_HOME=$GUEST_NIX_HOME/.config
TMPDIR=/run/diene-ci/tmp
export HOME XDG_CONFIG_HOME TMPDIR
cd /run/diene-ci
sha256sum -c archive-validator.sha256
chmod 0500 archive-validator.sh
./archive-validator.sh source.tar source
install -m 0600 receipt.json receipts/exact.json
install -d -m 0700 evidence/guest-nix
guest_nix_pinned_asset_valid() {
  asset=$1
  sidecar=$2
  expected_digest=$3
  expected_bytes=$4
  expected_line=${expected_digest#sha256:}'  '"$asset"
  [ -f "$asset" ] && [ ! -L "$asset" ] &&
    [ -f "$sidecar" ] && [ ! -L "$sidecar" ] &&
    [ "$(wc -c <"$asset")" -eq "$expected_bytes" ] &&
    [ "$(wc -l <"$sidecar")" -eq 1 ] &&
    [ "$(sha256sum "$asset")" = "$expected_line" ] &&
    [ "$(cat "$sidecar")" = "$expected_line" ] &&
    sha256sum -c "$sidecar" >/dev/null 2>&1
}
guest_nix_exact_output_valid() {
  stdout_file=$1
  stderr_file=$2
  expected_output=$3
  expected_output_bytes=$4
  [ -f "$stdout_file" ] && [ ! -L "$stdout_file" ] &&
    [ -f "$stderr_file" ] && [ ! -L "$stderr_file" ] &&
    [ ! -s "$stderr_file" ] &&
    [ "$(wc -c <"$stdout_file")" -eq "$expected_output_bytes" ] &&
    [ "$(wc -l <"$stdout_file")" -eq 1 ] &&
    [ "$(cat "$stdout_file")" = "$expected_output" ]
}
guest_nix_hash_etc_config() {
  [ -d /etc/nix ] && [ ! -L /etc/nix ] &&
    [ -f /etc/nix/nix.conf ] && [ ! -L /etc/nix/nix.conf ] &&
    [ -r /etc/nix/nix.conf ] || return 1
  sha256sum /etc/nix/nix.conf | cut -d" " -f1
}
guest_nix_plain_sha256_valid() {
  [ "${#1}" -eq 64 ] || return 1
  case $1 in *[!0-9a-f]*) return 1 ;; esac
}
guest_nix_installer_digest=__DIENE_GUEST_NIX_INSTALLER_DIGEST__
guest_nix_installer_bytes=__DIENE_GUEST_NIX_INSTALLER_BYTES__
guest_nix_payload_digest=__DIENE_GUEST_NIX_PAYLOAD_DIGEST__
guest_nix_payload_bytes=__DIENE_GUEST_NIX_PAYLOAD_BYTES__
[ "$(uname -m)" = x86_64 ] || guest_nix_fail GuestNixInstallerUnsupportedArch 'the guest architecture is not the pinned x86_64 target'
if [ "$guest_nix_inherited_nix_command" = present ] || [ -e /nix ] || [ -L /nix ] ||
  [ -e /etc/nix ] || [ -L /etc/nix ]; then
  guest_nix_fail GuestNixPreexistingState \
    'the ephemeral guest already contains Nix, /nix state, or /etc/nix state'
fi
guest_nix_pinned_asset_valid guest-nix-bootstrap.sh guest-nix-bootstrap.sha256 \
  "$guest_nix_installer_digest" "$guest_nix_installer_bytes" &&
  guest_nix_pinned_asset_valid guest-nix-installer guest-nix-installer.sha256 \
    "$guest_nix_payload_digest" "$guest_nix_payload_bytes" ||
  guest_nix_fail GuestNixInstallerUntrusted 'an uploaded guest Nix artifact or sidecar changed'
{
  cat guest-nix-bootstrap.sha256 guest-nix-installer.sha256
  printf '%s\n' 'executionMode=direct-pinned-binary' 'payloadDigestVerified=true'
} >evidence/guest-nix/verified.txt
chmod 0600 evidence/guest-nix/verified.txt guest-nix-bootstrap.sh guest-nix-installer
chmod 0500 guest-nix-installer
installer_version_stdout=evidence/guest-nix/installer-version.txt
installer_version_stderr=evidence/guest-nix/installer-version.stderr
: >"$installer_version_stdout"
: >"$installer_version_stderr"
chmod 0600 "$installer_version_stdout" "$installer_version_stderr"
if ! env -i PATH="$GUEST_NIX_PATH" HOME="$GUEST_NIX_HOME" TMPDIR=/run/diene-ci/tmp LC_ALL=C \
  ./guest-nix-installer --version >"$installer_version_stdout" 2>"$installer_version_stderr"; then
  guest_nix_fail GuestNixInstallerUntrusted 'the pinned installer version probe failed'
fi
guest_nix_exact_output_valid "$installer_version_stdout" "$installer_version_stderr" \
  'nix-installer 3.21.9' 21 ||
  guest_nix_fail GuestNixInstallerUntrusted 'the pinned installer version output is not exact'
install_rc=0
env -i PATH="$GUEST_NIX_PATH" HOME="$GUEST_NIX_HOME" TMPDIR=/run/diene-ci/tmp LC_ALL=C \
  NIX_INSTALLER_DIAGNOSTIC_ENDPOINT= \
  ./guest-nix-installer install linux --no-confirm --init none \
  >evidence/guest-nix/install.log 2>&1 || install_rc=$?
chmod 0600 evidence/guest-nix/install.log
[ "$install_rc" -eq 0 ] || guest_nix_fail GuestNixInstallFailed 'the pinned guest Nix installer failed'
guest_nix_etc_config_digest=$(guest_nix_hash_etc_config) ||
  guest_nix_fail GuestNixIdentityUnexpected \
    'the pinned installer did not create a safe regular /etc/nix/nix.conf'
guest_nix_plain_sha256_valid "$guest_nix_etc_config_digest" ||
  guest_nix_fail GuestNixIdentityUnexpected \
    'the installed /etc/nix/nix.conf digest is malformed'
guest_nix_profile=/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
guest_nix_profile_resolved=$(readlink -f "$guest_nix_profile" 2>/dev/null || printf '')
case $guest_nix_profile_resolved in
  /nix/store/*/etc/profile.d/nix-daemon.sh) ;;
  *) guest_nix_fail GuestNixIdentityUnexpected \
    'the exact guest Nix profile does not resolve into the pinned Nix store' ;;
esac
[ -f "$guest_nix_profile" ] && [ -r "$guest_nix_profile" ] ||
  guest_nix_fail GuestNixIdentityUnexpected \
    'the exact guest Nix profile is absent, unreadable, or not a regular file'
# Everything after the profile is sourced runs in shells that never saw the
# profile. Stage 2's whole program text, and the nix.conf digest bound before
# the profile existed, are fixed inside stage 1's text before stage 1 starts,
# and a freshly executed shell begins with an empty function table, its own
# variables and an argument list it did not choose. So no name the profile can
# reach - variable, function, alias, PATH entry, positional parameter, shell
# option or trap - is consulted by the recheck. Stage 1 runs no bare command
# after the profile returns, because BusyBox ash lets a sourced file shadow
# exec, exit, return and set, and expands a profile-defined alias into lines
# of the same program text parsed after the dot. An alias name cannot contain
# a slash and no function can shadow an absolute path, in either shell, so the
# one command stage 1 issues is /bin/sh spelled absolutely. Stage 2 restores
# the profile PATH only for the final fixed-path handoff.
guest_nix_stage2=$(cat <<'GUEST_NIX_STAGE2'
set -eu
umask 077
guest_nix_bound_config_digest=$1
guest_nix_profile_rc=$2
guest_nix_develop_path=$PATH
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
LC_ALL=C
export LC_ALL
cd /run/diene-ci
guest_nix_fail() { printf "%s: %s\n" "$1" "$2" >&2; exit 64; }
guest_nix_hash_etc_config() {
  [ -d /etc/nix ] && [ ! -L /etc/nix ] &&
    [ -f /etc/nix/nix.conf ] && [ ! -L /etc/nix/nix.conf ] &&
    [ -r /etc/nix/nix.conf ] || return 1
  sha256sum /etc/nix/nix.conf | cut -d" " -f1
}
[ "$guest_nix_profile_rc" -eq 0 ] ||
  guest_nix_fail GuestNixProfileSourceFailed "the exact guest Nix profile returned nonzero while being sourced"
guest_nix_profile_environment=$(env) ||
  guest_nix_fail GuestNixIdentityUnexpected \
    "the post-profile environment could not be enumerated"
guest_nix_profile_names_unsorted=$(printf "%s\n" "$guest_nix_profile_environment" |
  sed -n "s/^\(NIX[A-Za-z0-9_]*\)=.*\$/profileNixVar=\1/p") ||
  guest_nix_fail GuestNixIdentityUnexpected \
    "the post-profile Nix-family names could not be parsed"
guest_nix_profile_names=$(printf "%s\n" "$guest_nix_profile_names_unsorted" | LC_ALL=C sort) ||
  guest_nix_fail GuestNixIdentityUnexpected \
    "the post-profile Nix-family names could not be sorted"
if ! {
  printf "%s\n" "inheritedNixFamily=none"
  if [ -n "$guest_nix_profile_names" ]; then
    printf "%s\n" "$guest_nix_profile_names"
  fi
} >evidence/guest-nix/environment.txt; then
  guest_nix_fail GuestNixIdentityUnexpected \
    "the post-profile environment evidence could not be written"
fi
HOME=/run/diene-ci/home
XDG_CONFIG_HOME=/run/diene-ci/home/.config
NIX_USER_CONF_FILES=/run/diene-ci/nix-user.conf
export HOME XDG_CONFIG_HOME NIX_USER_CONF_FILES
: >"$NIX_USER_CONF_FILES"
chmod 0600 "$NIX_USER_CONF_FILES"
guest_nix_etc_config_digest_after_profile=$(guest_nix_hash_etc_config) ||
  guest_nix_fail GuestNixIdentityUnexpected \
    "the installed /etc/nix/nix.conf became unsafe before develop"
[ "$guest_nix_etc_config_digest_after_profile" = "$guest_nix_bound_config_digest" ] ||
  guest_nix_fail GuestNixIdentityUnexpected \
    "the installed /etc/nix/nix.conf changed before develop"
if ! {
  printf "home=%s\n" "$HOME"
  printf "xdgConfigHome=%s\n" "$XDG_CONFIG_HOME"
  printf "userConfFiles=%s\n" "$NIX_USER_CONF_FILES"
  printf "etcNixConf=%s\n" "$guest_nix_bound_config_digest"
} >>evidence/guest-nix/environment.txt; then
  guest_nix_fail GuestNixIdentityUnexpected \
    "the reviewed Nix environment evidence could not be completed"
fi
chmod 0600 evidence/guest-nix/environment.txt
[ -x /nix/var/nix/profiles/default/bin/nix ] || { printf "GuestNixToolchainAbsent: %s\n" "the instance provides no fixed-path nix command for the driver entry" >&2; exit 64; }
if ! /nix/var/nix/profiles/default/bin/nix --version >evidence/guest-nix/version.txt \
  2>evidence/guest-nix/version.stderr; then
  guest_nix_fail GuestNixIdentityUnexpected "the direct installed Nix identity probe failed"
fi
chmod 0600 evidence/guest-nix/version.txt evidence/guest-nix/version.stderr
PATH=$guest_nix_develop_path
export PATH
cd /run/diene-ci/source
exec /nix/var/nix/profiles/default/bin/nix --extra-experimental-features "nix-command flakes" develop .#ci -c ./scripts/ci/environment-k3d-run.sh driver /run/diene-ci
GUEST_NIX_STAGE2
)
# Stage 1 reads the profile path from its own argument list before the profile
# exists, so a later "set --" inside the profile cannot redirect it, and every
# "set" it needs runs before the profile is sourced. After the dot returns it
# performs exactly two operations: one variable assignment, which no function
# can intercept, and /bin/sh by absolute path. Nothing else is admissible
# here - BusyBox ash lets a sourced file shadow "return" and "set" as well as
# "exec" and "exit", so a helper that restored options or returned a status
# after the dot would let a profile erase its own nonzero source result. The
# stage-2 text and the bound digest are the opposite case: they are consulted
# after the profile has run, so they are carried as literal program text
# rather than as variables the profile could rebind.
guest_nix_stage1_head=$(cat <<'GUEST_NIX_STAGE1'
set -eu
guest_nix_profile=$1
set +eu
. "$guest_nix_profile"
guest_nix_profile_rc=$?
GUEST_NIX_STAGE1
)
guest_nix_stage1="$guest_nix_stage1_head
/bin/sh -c '$guest_nix_stage2' guest-nix-stage2 $guest_nix_etc_config_digest \"\$guest_nix_profile_rc\""
exec /bin/sh -c "$guest_nix_stage1" guest-nix-stage1 "$guest_nix_profile"
REMOTE
  )
  # The only runtime material inserted into the reviewed fixed template comes
  # from diene_guest_nix_contract after its strict URL/digest/length admission.
  # No uploaded file or sidecar contributes to these expected values.
  remote_command=${remote_command//__DIENE_GUEST_NIX_INSTALLER_DIGEST__/$installer_digest}
  remote_command=${remote_command//__DIENE_GUEST_NIX_INSTALLER_BYTES__/$installer_bytes}
  remote_command=${remote_command//__DIENE_GUEST_NIX_PAYLOAD_DIGEST__/$payload_digest}
  remote_command=${remote_command//__DIENE_GUEST_NIX_PAYLOAD_BYTES__/$payload_bytes}
  [[ $remote_command != *'__DIENE_GUEST_NIX_'* ]] ||
    diene_die InputContractInvalid 'guest Nix fixed remote command contains an unresolved pin placeholder'
  # Stage 2 is carried inside stage 1 as one single-quoted word, so a single
  # quote anywhere in its body would end that word and silently rewrite the
  # pristine program. The constraint is enforced on the materialized bytes so
  # a later edit of the template cannot corrupt the embedding unnoticed.
  guest_nix_stage2=$(awk '
    /^guest_nix_stage2=\$\(cat <<.GUEST_NIX_STAGE2.$/ { inside=1; next }
    /^GUEST_NIX_STAGE2$/ { inside=0 }
    inside
  ' <<<"$remote_command")
  [[ -n $guest_nix_stage2 && $guest_nix_stage2 != *"'"* ]] ||
    diene_die InputContractInvalid 'guest Nix pristine stage-2 text is absent or contains a single quote'
  printf '%s\n' "$remote_command"
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
  if ((ORCH_PUBLICATION_SAFE == 0)); then
    rm -f -- "${DIENE_CORE_REPORT:-$RUNNER_TEMP/diene-environment-report.v1.json}" \
      "${DIENE_VENDOR_REPORT:-$RUNNER_TEMP/diene-vendor-report.v1.json}" \
      "${DIENE_PROOF_BUNDLE:-$RUNNER_TEMP/diene-proof-bundle.tar}" 2>/dev/null || true
    orchestrator_fail "$DIENE_REASON_EXIT" EvidenceLeakageInterfaceUnavailable \
      'unsafe or unscannable collected evidence suppresses every report and proof artifact'
    return "$DIENE_REASON_EXIT"
  fi
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
    if ! (diene_checkpoint_validate "$checkpoint"); then
      orchestrator_fail "$DIENE_REASON_EXIT" CheckpointChainInvalid 'collected predecessor chain is invalid'
    elif ! jq -e '
      .validated == true and .resumedLegs == 0 and .finalCleanPass == true and
      (.checkpoints | length) > 0 and
      all(.checkpoints[]; .outcome == "Pass" and .resumed == false) and
      .checkpoints[-1].id == "final-clean-pass" and
      .checkpoints[-1].outcome == "Pass"
    ' "$checkpoint" >/dev/null; then
      orchestrator_fail "$DIENE_REASON_EXIT" FinalCleanPassRequired \
        'collected evidence is not a final clean full pass with zero resumed or failed legs'
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

  local source_digest subject_digest proof_digest total_seconds raw final_report final_bundle
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
    --arg nscVersion "$ORCH_NSC_VERSION" --arg nscArtifactDigest "$ORCH_NSC_ARTIFACT_DIGEST" \
    --arg nscBinaryDigest "$ORCH_NSC_BINARY_DIGEST" --arg sourceDigest "$source_digest" \
    --arg subjectDigest "$subject_digest" --arg proofDigest "$proof_digest" \
    --arg profileId "$(diene_egress_profile "$DIENE_LANE")" --arg verdict "$report_outcome" \
    --arg reason "$report_reason" --argjson createSeconds "$ORCH_CREATE_SECONDS" \
    --argjson transferSeconds "$ORCH_TRANSFER_SECONDS" --argjson collectionSeconds "$ORCH_COLLECTION_SECONDS" \
    --argjson destroySeconds "$ORCH_DESTROY_SECONDS" --argjson totalSeconds "$total_seconds" '
    .instance += {clusterId:$clusterId,osId:$osId,osVersion:$osVersion,k3sVersion:$k3sVersion,
      kubernetesVersion:$kubernetesVersion,nodeCount:$nodeCount,capacity:$capacity} |
    .tooling += {nscVersion:$nscVersion,nscArtifactDigest:$nscArtifactDigest,
      nscBinaryDigest:$nscBinaryDigest,sourceArchiveDigest:$sourceDigest,
      artifactSubjectDigest:$subjectDigest} |
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
  final_bundle=${DIENE_PROOF_BUNDLE:-$RUNNER_TEMP/diene-proof-bundle.tar}
  rm -f -- "$final_bundle"
  export DIENE_PROOF_BUNDLE_DIR=$ORCH_STATE
  local finalize_reason_file="$ORCH_STATE/report-finalize.reason" finalize_rc=0
  DIENE_REASON_FILE="$finalize_reason_file" \
    "$script_dir/environment-report.sh" --kind "$ORCH_KIND" --input "$raw" --output "$final_report" ||
    finalize_rc=$?
  if ((finalize_rc != 0)); then
    local finalize_reason=EvidenceLeakDetected
    [[ ! -s $finalize_reason_file ]] || IFS=$'\t' read -r finalize_reason _ <"$finalize_reason_file"
    ORCH_PUBLICATION_SAFE=0
    rm -f -- "${DIENE_CORE_REPORT:-$RUNNER_TEMP/diene-environment-report.v1.json}" \
      "${DIENE_VENDOR_REPORT:-$RUNNER_TEMP/diene-vendor-report.v1.json}" "$final_bundle" 2>/dev/null || true
    orchestrator_fail "$finalize_rc" "$finalize_reason" \
      'final outer proof-bundle scan or schema validation failed; every publication artifact was suppressed'
    return "$finalize_rc"
  fi

  [[ -f $ORCH_RECEIPT && ! -L $ORCH_RECEIPT ]] || {
    rm -f -- "$final_bundle"
    orchestrator_fail "$DIENE_REASON_EXIT" EvidenceCollectionFailed \
      'terminal proof cannot be sealed without the exact Namespace receipt'
    return "$DIENE_REASON_EXIT"
  }
  local report_digest lifecycle_digest checkpoint_digest
  report_digest=$(diene_file_digest "$final_report")
  lifecycle_digest=$(diene_file_digest "$lifecycle")
  checkpoint_digest=$(diene_file_digest "$checkpoint")
  # shellcheck disable=SC2016
  diene_receipt_patch "$ORCH_RECEIPT" '
    .checkpointChainDigest = $checkpointDigest |
    .lifecycleDigest = $lifecycleDigest |
    .terminalReportDigest = $terminalReportDigest
  ' --arg checkpointDigest "$checkpoint_digest" --arg lifecycleDigest "$lifecycle_digest" \
    --arg terminalReportDigest "$report_digest"
  diene_schema_validate diene-ci-receipt-v1.schema.json "$ORCH_RECEIPT" 'terminal Namespace receipt'
  if ((ORCH_FIRST_RC == 0)); then
    diene_validate_terminal_receipt "$ORCH_RECEIPT" "$lifecycle" "$checkpoint" "$final_report"
  fi

  local proof_dir="$ORCH_STATE/final-proof"
  install -d -m 0700 "$proof_dir"
  install -m 0600 "$final_report" "$proof_dir/$(basename -- "$final_report")"
  install -m 0600 "$lifecycle" "$proof_dir/namespace-lifecycle.json"
  install -m 0600 "$checkpoint" "$proof_dir/checkpoint-chain.json"
  install -m 0600 "$ORCH_RECEIPT" "$proof_dir/ci-receipt.json"
  local -a final_members=("$(basename -- "$final_report")" namespace-lifecycle.json \
    checkpoint-chain.json ci-receipt.json)
  tar -cf "$final_bundle" -C "$proof_dir" "${final_members[@]}"
  chmod 0600 "$final_bundle"
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
  if [[ $DIENE_LANE != ditto-vendor ]]; then
    diene_select_journeys "$DIENE_JOURNEY_MANIFEST" >/dev/null
  fi
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
  # Materialize one complete listing. Piping the listing into an early-exit
  # matcher is timing-sensitive under pipefail because the reader can close
  # early and make tar report SIGPIPE/141 even when the member is present.
  diene_require_archive_members "$ORCH_STATE/source.tar" \
    scripts/ci/environment-k3d-run.sh \
    schemas/ci/diene-environment-report-v1.schema.json

  local nsc_bin nsc_identity nsc_version nsc_artifact_digest nsc_binary_digest
  local source_digest subject_digest contract_digest validator_digest create_started create_rc
  local guest_nix_contract guest_nix_installer_digest guest_nix_payload_digest
  nsc_bin=$(diene_nsc_bin)
  nsc_identity=$(diene_nsc_identity)
  nsc_version=$(jq -r '.version' <<<"$nsc_identity")
  nsc_artifact_digest=$(jq -r '.artifactDigest' <<<"$nsc_identity")
  nsc_binary_digest=$(jq -r '.binaryDigest' <<<"$nsc_identity")
  ORCH_NSC_VERSION=$nsc_version
  ORCH_NSC_ARTIFACT_DIGEST=$nsc_artifact_digest
  ORCH_NSC_BINARY_DIGEST=$nsc_binary_digest
  export DIENE_NSC_VERSION=$nsc_version
  export DIENE_NSC_ARTIFACT_DIGEST=$nsc_artifact_digest
  export DIENE_NSC_BINARY_DIGEST=$nsc_binary_digest
  orchestrator_write_remote_archive_validator "$ORCH_STATE/archive-validator.sh"
  validator_digest=$(diene_file_digest "$ORCH_STATE/archive-validator.sh")
  printf '%s  archive-validator.sh\n' "${validator_digest#sha256:}" \
    >"$ORCH_STATE/archive-validator.sha256"
  chmod 0600 "$ORCH_STATE/archive-validator.sha256"
  guest_nix_contract=$(diene_guest_nix_contract) || exit $?
  guest_nix_installer_digest=$(jq -r '.installerDigest' <<<"$guest_nix_contract")
  guest_nix_payload_digest=$(jq -r '.payloadDigest' <<<"$guest_nix_contract")
  diene_fetch_pinned_artifact "$(jq -r '.installerUrl' <<<"$guest_nix_contract")" \
    "$guest_nix_installer_digest" "$(jq -r '.installerBytes' <<<"$guest_nix_contract")" \
    "$ORCH_STATE/guest-nix-bootstrap.sh"
  diene_fetch_pinned_artifact "$(jq -r '.payloadUrl' <<<"$guest_nix_contract")" \
    "$guest_nix_payload_digest" "$(jq -r '.payloadBytes' <<<"$guest_nix_contract")" \
    "$ORCH_STATE/guest-nix-installer"
  printf '%s  guest-nix-bootstrap.sh\n' "${guest_nix_installer_digest#sha256:}" \
    >"$ORCH_STATE/guest-nix-bootstrap.sha256"
  printf '%s  guest-nix-installer\n' "${guest_nix_payload_digest#sha256:}" \
    >"$ORCH_STATE/guest-nix-installer.sha256"
  chmod 0600 "$ORCH_STATE/guest-nix-bootstrap.sha256" "$ORCH_STATE/guest-nix-installer.sha256"
  source_digest=$(diene_file_digest "$ORCH_STATE/source.tar")
  subject_digest=$(diene_file_digest "$DIENE_ARTIFACT_SUBJECT")
  contract_digest=$(diene_file_digest "$ORCH_STATE/egress-contract.json")
  ORCH_STARTED=$SECONDS
  trap orchestrator_on_exit EXIT
  trap 'orchestrator_on_signal 143' TERM HUP
  trap 'orchestrator_on_signal 130' INT

  # One admission computed once. The create feature selector and the version
  # admitted to the guest are derived from the same validated value, so the
  # platform default can no longer silently supply a different minor.
  local k3s_admission admitted_k3s k3s_feature
  k3s_admission=$(diene_k3s_admission)
  admitted_k3s=${k3s_admission%% *}
  k3s_feature=${k3s_admission##* }

  local -a create=("$nsc_bin" create --ephemeral --duration 2h "--enable=$k3s_feature" \
    --wait_kube_system \
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
      "$ORCH_CREATE_DIGEST" "$ORCH_CREATE_SECONDS" false "$nsc_version" \
      "$nsc_artifact_digest" "$nsc_binary_digest")
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
    --arg nscVersion "$nsc_version" --arg nscArtifactDigest "$nsc_artifact_digest" \
    --arg nscBinaryDigest "$nsc_binary_digest" --arg sourceDigest "$source_digest" \
    --arg subjectDigest "$subject_digest" --arg archiveValidatorDigest "$validator_digest" \
    --arg contractDigest "$contract_digest" --arg canaryImage "$DIENE_EGRESS_CANARY_IMAGE" \
    --arg l7 "${DIENE_EGRESS_L7_ENFORCER_BIN:-}" --arg probe "${DIENE_EGRESS_PROBE_BIN:-}" \
    --arg vendorBroker "${DIENE_VENDOR_CREDENTIAL_BROKER_BIN:-}" \
    --arg k3s "$admitted_k3s" \
    --arg serviceCidr "${DIENE_K3S_SERVICE_CIDR:-10.143.0.0/16}" \
    --arg venue "${DIENE_ORCHESTRATOR_VENUE:-namespace}" \
    --arg label "${DIENE_ORCHESTRATOR_LABEL:-nscloud-ubuntu-26.04-amd64-16x32}" \
    --arg fallback "${DIENE_ORCHESTRATOR_FALLBACK_REASON:-}" \
    --argjson guestNix "$guest_nix_contract" '
    {apiVersion:"diene.atomi.cloud/ci-driver-inputs/v1",trustedRuntimeContext:"protected-base",
     duration:"2h",platformPolicyStatus:"platform per-instance policy pending (support ask #4)",
     owner:{repositoryId:$repositoryId,repositoryKey:$repositoryKey,sourceSha:$sourceSha,
       runId:$runId,runAttempt:$runAttempt,workflowRef:$workflowRef},lane:$lane,
     gardenLockDigest:$garden,artifact:{digest:$artifact,provenanceRef:$provenance,
       attestationDigest:$attestation},
     selectors:{journeyManifest:$journey,vendorManifest:$vendor,actionId:$action,fixtureId:$fixture},
     closure:{digest:$closure,bundleRef:$closureRef,signatureBundleDigest:$closureSignature,
       trustRootDigest:$closureRoot},clusterId:$clusterId,nscVersion:$nscVersion,
     nscArtifactDigest:$nscArtifactDigest,nscBinaryDigest:$nscBinaryDigest,
     archiveValidatorDigest:$archiveValidatorDigest,
     sourceArchiveDigest:$sourceDigest,artifactSubjectDigest:$subjectDigest,
     admittedK3sVersion:$k3s,admittedServiceCidr:$serviceCidr,cacheAttached:false,
     egress:{contractDigest:$contractDigest,canaryImage:$canaryImage,l7Enforcer:$l7,probeBin:$probe},
     vendorCredentialBroker:$vendorBroker,guestNix:$guestNix,
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
  ((transfer_rc != 0)) || "$nsc_bin" instance upload "$ORCH_CLUSTER_ID" "$ORCH_STATE/archive-validator.sh" \
    /run/diene-ci/archive-validator.sh --mkdir >>"$DIENE_EVIDENCE_STAGING/stdout" \
    2>>"$DIENE_EVIDENCE_STAGING/stderr" || transfer_rc=$?
  ((transfer_rc != 0)) || "$nsc_bin" instance upload "$ORCH_CLUSTER_ID" "$ORCH_STATE/archive-validator.sha256" \
    /run/diene-ci/archive-validator.sha256 --mkdir >>"$DIENE_EVIDENCE_STAGING/stdout" \
    2>>"$DIENE_EVIDENCE_STAGING/stderr" || transfer_rc=$?
  ((transfer_rc != 0)) || "$nsc_bin" instance upload "$ORCH_CLUSTER_ID" "$ORCH_STATE/guest-nix-bootstrap.sh" \
    /run/diene-ci/guest-nix-bootstrap.sh --mkdir >>"$DIENE_EVIDENCE_STAGING/stdout" \
    2>>"$DIENE_EVIDENCE_STAGING/stderr" || transfer_rc=$?
  ((transfer_rc != 0)) || "$nsc_bin" instance upload "$ORCH_CLUSTER_ID" "$ORCH_STATE/guest-nix-bootstrap.sha256" \
    /run/diene-ci/guest-nix-bootstrap.sha256 --mkdir >>"$DIENE_EVIDENCE_STAGING/stdout" \
    2>>"$DIENE_EVIDENCE_STAGING/stderr" || transfer_rc=$?
  ((transfer_rc != 0)) || "$nsc_bin" instance upload "$ORCH_CLUSTER_ID" "$ORCH_STATE/guest-nix-installer" \
    /run/diene-ci/guest-nix-installer --mkdir >>"$DIENE_EVIDENCE_STAGING/stdout" \
    2>>"$DIENE_EVIDENCE_STAGING/stderr" || transfer_rc=$?
  ((transfer_rc != 0)) || "$nsc_bin" instance upload "$ORCH_CLUSTER_ID" "$ORCH_STATE/guest-nix-installer.sha256" \
    /run/diene-ci/guest-nix-installer.sha256 --mkdir >>"$DIENE_EVIDENCE_STAGING/stdout" \
    2>>"$DIENE_EVIDENCE_STAGING/stderr" || transfer_rc=$?
  ORCH_TRANSFER_SECONDS=$((SECONDS - transfer_started))
  ORCH_TRANSFER_DIGEST=$(phase_digest transfer "$source_digest|$guest_nix_installer_digest" \
    "$contract_digest|$validator_digest|$guest_nix_payload_digest")
  if ((transfer_rc != 0)); then
    ORCH_TRANSFER_OUTCOME=Fail
    ORCH_TRANSFER_REASON=NamespaceTransferFailed
    orchestrator_fail "$transfer_rc" NamespaceTransferFailed 'fixed immutable upload failed'
    return "$transfer_rc"
  fi
  ORCH_TRANSFER_OUTCOME=Pass
  ORCH_TRANSFER_REASON=ImmutableInputsUploaded

  local remote_command ssh_started ssh_rc=0
  remote_command=$(orchestrator_fixed_remote_command)
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
    else
      orchestrator_fail "$DIENE_REASON_EXIT" EvidenceCollectionFailed \
        'collected driver proof omitted the exact Namespace receipt'
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
  local nsc_identity
  nsc_identity=$(diene_nsc_identity)
  export DIENE_NSC_VERSION DIENE_NSC_ARTIFACT_DIGEST DIENE_NSC_BINARY_DIGEST
  DIENE_NSC_VERSION=$(jq -r '.version' <<<"$nsc_identity")
  DIENE_NSC_ARTIFACT_DIGEST=$(jq -r '.artifactDigest' <<<"$nsc_identity")
  DIENE_NSC_BINARY_DIGEST=$(jq -r '.binaryDigest' <<<"$nsc_identity")
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

orchestrator_verify_lifecycle() (
  local bundle=${1:?proof bundle required}
  diene_validate_inputs
  diene_require_command jq
  diene_require_command tar
  [[ -f $bundle && ! -L $bundle ]] ||
    diene_die EvidenceCollectionFailed 'workflow-owned lifecycle proof bundle is absent or unsafe'
  diene_archive_is_safe "$bundle" ||
    diene_die EvidenceCollectionFailed \
      'lifecycle proof contains an unsafe name, link, device, FIFO, socket, or other special member'
  local schema=diene-environment-report-v1.schema.json
  local report_member=diene-environment-report.v1.json
  if [[ $DIENE_LANE == ditto-vendor ]]; then
    schema=diene-vendor-report-v1.schema.json
    report_member=diene-vendor-report.v1.json
  fi
  local listing extract
  listing=$(mktemp "${RUNNER_TEMP:-/tmp}/diene-lifecycle-list.XXXXXX")
  extract=$(mktemp -d "${RUNNER_TEMP:-/tmp}/diene-lifecycle-proof.XXXXXX")
  trap 'rm -f -- "$listing"; chmod -R u+rwX "$extract" 2>/dev/null || true; rm -r -- "$extract" 2>/dev/null || true' EXIT
  LC_ALL=C tar --list --quoting-style=escape --file "$bundle" >"$listing" ||
    diene_die EvidenceCollectionFailed 'lifecycle proof tar is unreadable'
  awk -v report="$report_member" '
    $0 == report {reports++; next}
    $0 == "namespace-lifecycle.json" {lifecycles++; next}
    $0 == "checkpoint-chain.json" {checkpoints++; next}
    $0 == "ci-receipt.json" {receipts++; next}
    {bad=1}
    END {
      exit (bad || NR != 4 || reports != 1 || lifecycles != 1 || checkpoints != 1 || receipts != 1) ? 1 : 0
    }
  ' "$listing" ||
    diene_die EvidenceCollectionFailed \
      'lifecycle proof must contain exactly the terminal report, lifecycle, checkpoint, and receipt'
  tar --extract --no-same-owner --no-same-permissions --keep-old-files \
    -f "$bundle" -C "$extract" ||
    diene_die EvidenceCollectionFailed 'lifecycle proof could not be extracted safely'
  diene_tree_is_safe "$extract" ||
    diene_die EvidenceCollectionFailed 'lifecycle proof contains an unreadable or special object'

  local report="$extract/$report_member"
  diene_schema_validate "$schema" "$report" \
    'workflow-owned terminal report'
  local lifecycle="$extract/namespace-lifecycle.json" checkpoint="$extract/checkpoint-chain.json"
  local receipt="$extract/ci-receipt.json" nsc_identity
  local lifecycle_nsc_version lifecycle_nsc_artifact_digest lifecycle_nsc_binary_digest
  nsc_identity=$(diene_nsc_identity_record)
  lifecycle_nsc_version=$(jq -r '.version' <<<"$nsc_identity")
  lifecycle_nsc_artifact_digest=$(jq -r '.artifactDigest' <<<"$nsc_identity")
  lifecycle_nsc_binary_digest=$(jq -r '.binaryDigest' <<<"$nsc_identity")
  local cluster_id receipt_id
  cluster_id=$(jq -er '.clusterId | select(type == "string" and length > 0)' "$lifecycle") ||
    diene_die NamespaceIdentityMismatch 'terminal lifecycle has no exact cluster_id'
  receipt_id=$(diene_receipt_id)
  diene_require_safe_id cluster_id "$cluster_id"
  jq -e \
    --arg sha "$GITHUB_SHA" --arg runId "$GITHUB_RUN_ID" --arg runAttempt "$GITHUB_RUN_ATTEMPT" \
    --arg lane "$DIENE_LANE" --arg receipt "$receipt_id" --arg cluster "$cluster_id" \
    --arg nscVersion "$lifecycle_nsc_version" \
    --arg nscArtifactDigest "$lifecycle_nsc_artifact_digest" \
    --arg nscBinaryDigest "$lifecycle_nsc_binary_digest" '
    .repositoryRevision == $sha and .workflow.runId == $runId and
    .workflow.runAttempt == $runAttempt and .lane == $lane and .receiptId == $receipt and
    .instance.clusterId == $cluster and .namespaceLifecycle.clusterId == $cluster and
    .tooling.nscVersion == $nscVersion and .tooling.nscArtifactDigest == $nscArtifactDigest and
    .tooling.nscBinaryDigest == $nscBinaryDigest and
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
    all(.checkpointChain.checkpoints[]; .outcome == "Pass" and .resumed == false) and
    .checkpointChain.checkpoints[-1].id == "final-clean-pass"
  ' "$report" >/dev/null ||
    diene_die NamespaceLifecycleFailed 'terminal report is not a green exact-id lifecycle proof'
  diene_checkpoint_validate "$checkpoint"
  jq -e '
    .validated == true and .finalCleanPass == true and .resumedLegs == 0 and
    all(.checkpoints[]; .outcome == "Pass" and .resumed == false) and
    .checkpoints[-1].id == "final-clean-pass" and .checkpoints[-1].outcome == "Pass"
  ' "$checkpoint" >/dev/null ||
    diene_die FinalCleanPassRequired 'terminal checkpoint chain is not a clean full pass'
  DIENE_NSC_VERSION=$lifecycle_nsc_version \
    DIENE_NSC_ARTIFACT_DIGEST=$lifecycle_nsc_artifact_digest \
    DIENE_NSC_BINARY_DIGEST=$lifecycle_nsc_binary_digest \
    diene_validate_terminal_receipt "$receipt" "$lifecycle" "$checkpoint" "$report"
  printf 'NamespaceLifecycleVerified: %s\n' "$cluster_id"
)

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
    --arg nscArtifactDigest "$DIENE_NSC_ARTIFACT_DIGEST" \
    --arg nscBinaryDigest "$DIENE_NSC_BINARY_DIGEST" \
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
       nscArtifactDigest:$nscArtifactDigest,nscBinaryDigest:$nscBinaryDigest,
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

diene_core_driver_preflight() {
  "$script_dir/environment-runner-preflight.sh" "$@"
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
  if [[ $DIENE_LANE == fleet-independence ]]; then
    jq -cn '{id:"fleet-endpoint-resource-negative-probe",outcome:"Unavailable",
      reasonCode:"FleetEndpointResourceNegativeProbeContractUnavailable",required:false}' \
      >>"$DRIVER_COVERAGE"
  fi
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
  diene_core_driver_preflight --output "$preflight"
  diene_checkpoint_append "$DRIVER_CHECKPOINT" instance-preflight Pass "$(diene_file_digest "$preflight")" false

  local manifest=$DIENE_JOURNEY_MANIFEST

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

  local journeys_started=$SECONDS selection="$DRIVER_RUNTIME_DIR/selection.jsonl"
  diene_select_journeys "$manifest" "$selection"
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
  [[ -s $DRIVER_RESULTS ]] ||
    diene_die JourneySelectorUnsatisfied 'selected core journey set produced no executed result'
  DRIVER_JOURNEY_SECONDS=$((SECONDS - journeys_started))
  ((required_failure == 0)) || diene_die JourneyFailed 'a required journey did not pass'
  diene_checkpoint_append "$DRIVER_CHECKPOINT" journeys Pass \
    "$(phase_digest journeys "$DIENE_LANE" "$DRIVER_JOURNEY_SECONDS")" false

  diene_verify_endpoint_law "$DRIVER_RUNTIME_DIR/endpoint-law.json"
}

environment_k3d_main() {
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
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  environment_k3d_main "$@"
fi
