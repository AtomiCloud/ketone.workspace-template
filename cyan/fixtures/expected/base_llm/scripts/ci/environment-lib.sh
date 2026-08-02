#!/usr/bin/env bash
# Shared contract helpers for the retained environment-k3d compatibility ABI.
# The active substrate is one anonymous Namespace instance with built-in k3s.
# `environment-k3d` and `diene-ci-k3d/v1` remain opaque compatibility names;
# no helper in this file creates nested k3d, Docker state, public ingress, or a
# second lifecycle beside the ratified `pls env` surface.
set -euo pipefail

DIENE_REASON_EXIT=64
DIENE_ZERO_DIGEST=sha256:0000000000000000000000000000000000000000000000000000000000000000
DIENE_NSC_EXPECTED_VERSION=v0.0.532
DIENE_GUEST_NIX_INSTALLER_URL=https://install.determinate.systems/nix/tag/v3.21.9
DIENE_GUEST_NIX_INSTALLER_DIGEST=sha256:ed6067b13423cfd36c50e5b156b9e08eb3a7bea4dde8cb1c8d997d757b37b7f6
DIENE_GUEST_NIX_INSTALLER_BYTES=19299
DIENE_GUEST_NIX_PAYLOAD_URL=https://install.determinate.systems/nix/tag/v3.21.9/nix-installer-x86_64-linux
DIENE_GUEST_NIX_PAYLOAD_DIGEST=sha256:58cf15422853e95187405d66b0cdb306e66f602218ee0032386c46b1b776a6d1
DIENE_GUEST_NIX_PAYLOAD_BYTES=73234640
DIENE_GUEST_NIX_EXPECTED_INSTALLER_VERSION='nix-installer 3.21.9'
DIENE_GUEST_NIX_EXPECTED_IDENTITY='nix (Determinate Nix 3.21.9) 2.34.8'
DIENE_GUEST_NIX_EXPECTED_IDENTITY_BYTES=36
DIENE_GUEST_NIX_ARCH=x86_64
DIENE_GUEST_NIX_EXECUTION_MODE=direct-pinned-binary
DIENE_GUEST_NIX_PROFILE=/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
DIENE_GUEST_NIX_BIN=/nix/var/nix/profiles/default/bin/nix
DIENE_GUEST_NIX_STORE_ROOT=/nix/store
DIENE_GUEST_NIX_INSTALLED_COPY=/nix/nix-installer
DIENE_GUEST_TOOLCHAIN_EXECUTION_MODE=offline-pinned-apk
DIENE_GUEST_TOOLCHAIN_APK_BIN=/usr/bin/apk
DIENE_GUEST_TOOLCHAIN_DIR=/run/diene-ci/gnu
DIENE_GUEST_TOOLCHAIN_REPO_BASE=https://apk.cgr.dev/chainguard/x86_64
DIENE_GUEST_TOOLCHAIN_ARCH=x86_64
DIENE_GUEST_TOOLCHAIN_RULED_SET='coreutils findutils sed grep gawk'
DIENE_GUEST_TOOLCHAIN_CLOSURE_SET='libacl1 libattr1 libpcre2-8-0 libsepol libselinux coreutils findutils gawk grep sed'
DIENE_GUEST_TOOLCHAIN_PACKAGES='libacl1|2.4.0-r1|34550|sha256:061726fa4e99053cdf848613d34361f1f983cddb71dbc2928268c2cbc215756f
libattr1|2.6.0-r1|19401|sha256:5890faac103dcbb230b6a9c7e8ece1bbf9f7b622b5b7a3b2fb88cbe163a0a70a
libpcre2-8-0|10.47-r0|307247|sha256:579084d2b3f53f6f7224f5eb0e050fbbd01e7a535bdf50551cf51eb74e29b8aa
libsepol|3.11-r0|459575|sha256:d8ff742c93586933f063b2cec5208fd143681f79cff1ba617d39de04e822d5e2
libselinux|3.11-r0|332224|sha256:6a03897e1a50cfea06e8575c532591e0e39b8f966797ca2532d08c165aab1606
coreutils|9.11-r3|859851|sha256:8c4fa14bd0f057ab22e7089a842b7f57a15acf34ec4c63488660c0e05fac22a7
findutils|4.11.0-r1|222062|sha256:28c342bc2d3bf10b23e6de8544bdcb16fe0d7387ffc57d89391716df051cea88
gawk|5.4.1-r0|1093813|sha256:2b2d4389aa720ce3baf6d8889fc2589d207828318e55552ba6469c822b6ed392
grep|3.12-r6|285444|sha256:61d6f87d5968a4b56af721d44328485ed01909b39c260a0729fd4b72ff08ab70
sed|4.10-r1|341772|sha256:64f97fb24d76be3d835114b93ef77385c82a8f3b432a775ed72394e86171f28c'

diene_die() {
  local code=${1:?reason code required}
  shift
  printf '%s: %s\n' "$code" "$*" >&2
  if [[ -n ${DIENE_REASON_FILE:-} ]]; then
    printf '%s\t%s\n' "$code" "$*" >"$DIENE_REASON_FILE" || true
  fi
  exit "$DIENE_REASON_EXIT"
}

diene_warn() {
  local code=${1:?reason code required}
  shift
  printf '%s: %s\n' "$code" "$*" >&2
}

diene_require_command() {
  command -v "$1" >/dev/null 2>&1 || diene_die DependencyUnavailable "$1 is required"
}

diene_require_full_sha() {
  [[ ${2:-} =~ ^[0-9a-f]{40}$ ]] || diene_die InputContractInvalid "$1 must be a full lowercase commit"
}

diene_require_digest() {
  [[ ${2:-} =~ ^sha256:[0-9a-f]{64}$ ]] || diene_die InputContractInvalid "$1 must be sha256:<64 lowercase hex>"
}

diene_require_safe_id() {
  [[ ${2:-} =~ ^[A-Za-z0-9][A-Za-z0-9._:-]{0,255}$ ]] ||
    diene_die InputContractInvalid "$1 is not a safe exact identifier"
}

diene_timestamp() {
  date -u +'%Y-%m-%dT%H:%M:%SZ'
}

diene_sha256_text() {
  printf 'sha256:%s\n' "$(printf '%s' "${1-}" | sha256sum | awk '{print $1}')"
}

diene_file_digest() {
  local path=${1:?path required}
  [[ -f $path && ! -L $path ]] || diene_die InputContractInvalid "$path is not a regular file"
  printf 'sha256:%s\n' "$(sha256sum -- "$path" | awk '{print $1}')"
}

diene_write_json() {
  local target=${1:?target required}
  local tmp="$target.tmp.$$"
  install -d -m 0700 "$(dirname -- "$target")"
  cat >"$tmp"
  chmod 0600 "$tmp"
  mv -- "$tmp" "$target"
}

# The tagged shell is retained only as an unexecuted provenance witness. The
# architecture-specific binary is the sole execution trust root. This helper
# emits the one canonical schema-free contract object consumed by the host
# acquisition path, immutable driver inputs, and in-guest identity proof.
diene_guest_nix_contract() {
  local installer_url=$DIENE_GUEST_NIX_INSTALLER_URL
  local installer_digest=$DIENE_GUEST_NIX_INSTALLER_DIGEST
  local installer_bytes=$DIENE_GUEST_NIX_INSTALLER_BYTES
  local payload_url=$DIENE_GUEST_NIX_PAYLOAD_URL
  local payload_digest=$DIENE_GUEST_NIX_PAYLOAD_DIGEST
  local payload_bytes=$DIENE_GUEST_NIX_PAYLOAD_BYTES
  local architecture=$DIENE_GUEST_NIX_ARCH
  local installer_version=$DIENE_GUEST_NIX_EXPECTED_INSTALLER_VERSION
  local nix_version=$DIENE_GUEST_NIX_EXPECTED_IDENTITY
  local execution_mode=$DIENE_GUEST_NIX_EXECUTION_MODE
  local major minor patch LC_ALL=C

  if [[ $installer_url =~ ^https://install\.determinate\.systems/nix/tag/v([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
    major=${BASH_REMATCH[1]}
    minor=${BASH_REMATCH[2]}
    patch=${BASH_REMATCH[3]}
  else
    diene_die InputContractInvalid 'guest Nix provenance URL must be one immutable tagged HTTPS endpoint'
  fi
  [[ $architecture == x86_64 ]] ||
    diene_die InputContractInvalid 'guest Nix contract supports only the pinned x86_64 architecture'
  [[ $payload_url == "$installer_url/nix-installer-$architecture-linux" ]] ||
    diene_die InputContractInvalid 'guest Nix payload URL is not the exact pinned tag and architecture asset'
  diene_require_digest guest-nix-installer-digest "$installer_digest"
  diene_require_digest guest-nix-payload-digest "$payload_digest"
  [[ $installer_bytes =~ ^[1-9][0-9]*$ && $payload_bytes =~ ^[1-9][0-9]*$ ]] ||
    diene_die InputContractInvalid 'guest Nix pinned byte lengths must be positive decimal integers'
  [[ $installer_version == "nix-installer $major.$minor.$patch" ]] ||
    diene_die InputContractInvalid 'guest Nix installer version does not match the pinned tag'
  [[ $nix_version =~ ^[[:print:]]+$ && ${#nix_version} == 35 &&
    $DIENE_GUEST_NIX_EXPECTED_IDENTITY_BYTES == 36 ]] ||
    diene_die InputContractInvalid \
      'guest Nix expected identity must be the exact 35-byte printable line plus one newline'
  [[ $execution_mode == direct-pinned-binary ]] ||
    diene_die InputContractInvalid 'guest Nix execution mode must be the direct pinned binary'
  [[ $DIENE_GUEST_NIX_PROFILE == /nix/* && $DIENE_GUEST_NIX_BIN == /nix/* &&
    $DIENE_GUEST_NIX_STORE_ROOT == /nix/store && $DIENE_GUEST_NIX_INSTALLED_COPY == /nix/* ]] ||
    diene_die InputContractInvalid 'guest Nix fixed profile and identity paths are invalid'

  jq -cn \
    --arg installerUrl "$installer_url" --arg installerDigest "$installer_digest" \
    --argjson installerBytes "$installer_bytes" --arg payloadUrl "$payload_url" \
    --arg payloadDigest "$payload_digest" --argjson payloadBytes "$payload_bytes" \
    --arg architecture "$architecture" --arg executionMode "$execution_mode" \
    --arg installerVersion "$installer_version" --arg nixVersion "$nix_version" \
    --arg profilePath "$DIENE_GUEST_NIX_PROFILE" --arg nixBinPath "$DIENE_GUEST_NIX_BIN" \
    --arg storeRoot "$DIENE_GUEST_NIX_STORE_ROOT" \
    --arg installedCopyPath "$DIENE_GUEST_NIX_INSTALLED_COPY" '
    {installerUrl:$installerUrl,installerDigest:$installerDigest,installerBytes:$installerBytes,
     payloadUrl:$payloadUrl,payloadDigest:$payloadDigest,payloadBytes:$payloadBytes,
     payloadDigestVerified:true,architecture:$architecture,executionMode:$executionMode,
     argv:["install","linux","--no-confirm","--init","none"],
     installerVersion:$installerVersion,nixVersion:$nixVersion,initMode:"none",
     profilePath:$profilePath,nixBinPath:$nixBinPath,storeRoot:$storeRoot,
     installedCopyPath:$installedCopyPath}'
}

# Emit the one canonical schema-free Wolfi GNU bootstrap contract. The ruled
# package set and its measured dependency closure are separate fixed allowlists:
# neither a missing transitive package nor an extra package can silently widen
# the offline install. Package objects are name-sorted before serialization,
# while argv retains the reviewed dependency-first install order.
diene_guest_toolchain_contract() {
  local execution_mode=$DIENE_GUEST_TOOLCHAIN_EXECUTION_MODE
  local apk_bin=$DIENE_GUEST_TOOLCHAIN_APK_BIN package_dir=$DIENE_GUEST_TOOLCHAIN_DIR
  local repo_base=$DIENE_GUEST_TOOLCHAIN_REPO_BASE architecture=$DIENE_GUEST_TOOLCHAIN_ARCH
  local ruled_set=$DIENE_GUEST_TOOLCHAIN_RULED_SET closure_set=$DIENE_GUEST_TOOLCHAIN_CLOSURE_SET
  local expected_ruled='coreutils findutils sed grep gawk'
  local expected_closure='libacl1 libattr1 libpcre2-8-0 libsepol libselinux coreutils findutils gawk grep sed'
  local packages='[]' argv_paths='[]' seen=' ' count=0
  local name version bytes digest extra filename path sidecar_filename sidecar_path package required
  local LC_ALL=C

  [[ $execution_mode == offline-pinned-apk && $apk_bin == /usr/bin/apk &&
    $package_dir == /run/diene-ci/gnu &&
    $repo_base == https://apk.cgr.dev/chainguard/x86_64 &&
    $architecture == x86_64 ]] ||
    diene_die InputContractInvalid 'guest toolchain fixed execution, path, repository, or architecture changed'
  [[ $ruled_set == "$expected_ruled" && $closure_set == "$expected_closure" ]] ||
    diene_die InputContractInvalid 'guest toolchain ruled or closure allowlist changed'

  while IFS='|' read -r name version bytes digest extra; do
    [[ -n $name && -n $version && -n $bytes && -n $digest && -z ${extra:-} ]] ||
      diene_die InputContractInvalid 'guest toolchain package row is malformed'
    case " $expected_closure " in
      *" $name "*) ;;
      *) diene_die InputContractInvalid "guest toolchain package $name is outside the fixed closure" ;;
    esac
    [[ $name =~ ^[a-z0-9][a-z0-9-]*$ &&
      $version =~ ^[0-9][0-9A-Za-z._+-]*-r[0-9]+$ &&
      $bytes =~ ^[1-9][0-9]*$ ]] ||
      diene_die InputContractInvalid "guest toolchain package row for $name is malformed"
    diene_require_digest "guest-toolchain-$name-digest" "$digest"
    case $seen in
      *" $name "*) diene_die InputContractInvalid "guest toolchain package $name is duplicated" ;;
    esac
    seen+="$name "
    count=$((count + 1))
    filename="$name-$version.apk"
    path="$package_dir/$filename"
    sidecar_filename="$filename.sha256"
    sidecar_path="$package_dir/$sidecar_filename"
    package=$(jq -cn --arg name "$name" --arg version "$version" --argjson bytes "$bytes" \
      --arg digest "$digest" --arg filename "$filename" --arg path "$path" \
      --arg sidecarFilename "$sidecar_filename" --arg sidecarPath "$sidecar_path" \
      '{name:$name,version:$version,bytes:$bytes,digest:$digest,filename:$filename,path:$path,
        sidecarFilename:$sidecarFilename,sidecarPath:$sidecarPath}')
    packages=$(jq -cn --argjson old "$packages" --argjson package "$package" '$old + [$package]')
    argv_paths=$(jq -cn --argjson old "$argv_paths" --arg path "$path" '$old + [$path]')
  done <<<"$DIENE_GUEST_TOOLCHAIN_PACKAGES"

  [[ $count == 10 ]] ||
    diene_die InputContractInvalid 'guest toolchain closure must contain exactly ten packages'
  for required in $expected_closure; do
    case $seen in
      *" $required "*) ;;
      *) diene_die InputContractInvalid "guest toolchain closure is missing $required" ;;
    esac
  done
  packages=$(jq -cS 'sort_by(.name)' <<<"$packages")

  jq -cn --arg executionMode "$execution_mode" --arg apkBinPath "$apk_bin" \
    --arg packageDir "$package_dir" --arg repositoryBase "$repo_base" \
    --arg architecture "$architecture" --arg ruledSet "$ruled_set" \
    --arg closureSet "$closure_set" --argjson packages "$packages" \
    --argjson argvPaths "$argv_paths" '
    {executionMode:$executionMode,apkBinPath:$apkBinPath,packageDir:$packageDir,
     repositoryBase:$repositoryBase,architecture:$architecture,
     ruledPackages:($ruledSet | split(" ")),closurePackages:($closureSet | split(" ")),
     packages:$packages,
     argv:(["add","--no-progress","--no-network","--allow-untrusted"] + $argvPaths)}'
}

diene_guest_toolchain_contract_digest() {
  local contract
  contract=$(diene_guest_toolchain_contract) || return $?
  diene_sha256_text "$(jq -cS . <<<"$contract")"
}

# Resolve the reviewed production downloader to its immutable Nix-store
# executable. Tests may redefine this function only inside their isolated
# scratch copy; no inherited path-valued override is an accepted seam.
diene_pinned_downloader() {
  local untrusted_code=${1:-GuestNixInstallerUntrusted}
  local artifact_label=${2:-guest Nix}
  local candidate resolved
  candidate=$(command -v curl) ||
    diene_die DependencyUnavailable "curl is required for pinned $artifact_label acquisition"
  resolved=$(readlink -f -- "$candidate") ||
    diene_die "$untrusted_code" 'the reviewed curl executable could not be resolved'
  [[ $resolved == /nix/store/*/bin/curl && -f $resolved && -x $resolved ]] ||
    diene_die "$untrusted_code" \
      'the reviewed curl executable is not an immutable Nix-store binary'
  printf '%s\n' "$resolved"
}

# Acquire one immutable artifact without publishing partial or unverified
# bytes. The default redirect budget remains zero. Wolfi package URLs alone
# receive an explicit budget of one because the immutable endpoint responds
# with one HTTPS 303 to an expiring object URL; exact length and digest pins
# remain the content authority, and --proto-redir forbids downgrade.
diene_fetch_pinned_artifact() {
  local url=${1:?artifact URL required} digest=${2:?artifact digest required}
  local expected_bytes=${3:?artifact byte length required} target=${4:?artifact target required}
  local max_redirs=${5:-0}
  local curl_bin target_dir tmp actual_bytes actual_digest
  local untrusted_code=GuestNixInstallerUntrusted artifact_label='guest Nix'
  if [[ $max_redirs == 1 ]]; then
    untrusted_code=GuestToolchainUntrusted
    artifact_label='guest toolchain'
  fi
  [[ ${DIENE_CURL_BIN+x} != x ]] ||
    diene_die "$untrusted_code" \
      "an ambient $artifact_label downloader override is prohibited"
  curl_bin=$(diene_pinned_downloader "$untrusted_code" "$artifact_label") || return $?
  diene_require_digest "$artifact_label-artifact-digest" "$digest"
  [[ $url == https://* && $expected_bytes =~ ^[1-9][0-9]*$ && $max_redirs =~ ^[01]$ ]] ||
    diene_die InputContractInvalid "$artifact_label artifact acquisition inputs are invalid"
  if [[ $max_redirs == 1 &&
    $url != "$DIENE_GUEST_TOOLCHAIN_REPO_BASE/"*.apk ]]; then
    diene_die InputContractInvalid \
      'one redirect is permitted only for the digest-pinned Wolfi package artifact class'
  fi
  diene_require_command "$curl_bin"
  diene_require_command ln
  diene_require_command mktemp
  diene_require_command stat
  diene_require_command wc
  target_dir=$(dirname -- "$target")
  [[ -d $target_dir && ! -L $target_dir ]] ||
    diene_die "$untrusted_code" \
      "$artifact_label publication directory is absent, linked, or not a real directory"
  [[ ! -e $target && ! -L $target ]] ||
    diene_die "$untrusted_code" "$artifact_label publication target is not fresh"
  tmp=$(mktemp "$target.tmp.XXXXXX") ||
    diene_die "$untrusted_code" "private $artifact_label artifact temporary file could not be created"
  chmod 0600 "$tmp" || {
    rm -f -- "$tmp"
    diene_die "$untrusted_code" "$artifact_label artifact temporary file could not be sealed"
  }
  if ! "$curl_bin" --fail --show-error --silent --proto '=https' --proto-redir '=https' --tlsv1.2 \
    --location --max-redirs "$max_redirs" --max-time 120 --retry 0 --output "$tmp" "$url"; then
    rm -f -- "$tmp"
    diene_die "$untrusted_code" "$artifact_label pinned HTTPS acquisition failed or redirected"
  fi
  actual_bytes=$(wc -c <"$tmp")
  if [[ $actual_bytes != "$expected_bytes" ]]; then
    rm -f -- "$tmp"
    diene_die "$untrusted_code" "$artifact_label artifact byte length does not match the pin"
  fi
  actual_digest=$(diene_file_digest "$tmp")
  if [[ $actual_digest != "$digest" ]]; then
    rm -f -- "$tmp"
    diene_die "$untrusted_code" "$artifact_label artifact digest does not match the pin"
  fi
  # A same-directory hard-link publication is atomic and, unlike a replacing
  # rename, fails if a regular or symlink target appears before publication.
  if ! chmod 0600 "$tmp" || ! ln -- "$tmp" "$target"; then
    rm -f -- "$tmp"
    diene_die "$untrusted_code" "verified $artifact_label artifact could not be atomically published"
  fi
  if ! rm -f -- "$tmp"; then
    rm -f -- "$target" "$tmp"
    diene_die "$untrusted_code" "$artifact_label publication temporary link could not be removed"
  fi
  [[ -f $target && ! -L $target && $(stat -c %a -- "$target") == 600 ]] ||
    diene_die "$untrusted_code" "published $artifact_label artifact is not a private regular file"
}

diene_guest_nix_evidence_dir() {
  local staging=${DIENE_EVIDENCE_STAGING:-} dir
  [[ $staging == /* && -d $staging && ! -L $staging && ${staging##*/} == staging ]] ||
    diene_die GuestNixIdentityUnexpected \
      'guest Nix identity requires an absolute driver-owned evidence staging directory'
  dir="${staging%/staging}/guest-nix"
  [[ ! -L $dir ]] ||
    diene_die GuestNixIdentityUnexpected 'guest Nix evidence directory is a symlink'
  install -d -m 0700 "$dir" ||
    diene_die GuestNixIdentityUnexpected 'guest Nix evidence directory could not be created'
  [[ -d $dir && ! -L $dir ]] ||
    diene_die GuestNixIdentityUnexpected 'guest Nix evidence directory is not a real directory'
  printf '%s\n' "$dir"
}

diene_source_guest_nix_profile() {
  local profile=${1:?guest Nix profile required} test_root=${2:-} profile_rc resolved
  [[ -f $profile && -r $profile ]] ||
    diene_die GuestNixIdentityUnexpected \
      'the exact guest Nix profile is absent, unreadable, or not a regular file'
  resolved=$(readlink -f -- "$profile") ||
    diene_die GuestNixIdentityUnexpected \
      'the exact guest Nix profile could not be resolved'
  if [[ -n $test_root ]]; then
    [[ $test_root == /* && -d $test_root && ! -L $test_root &&
      $profile == "$test_root"/* && $resolved == "$test_root"/* ]] ||
      diene_die InputContractInvalid \
        'the fake guest Nix profile is outside its explicit test root'
  else
    [[ $profile == "$DIENE_GUEST_NIX_PROFILE" &&
      $resolved == /nix/store/*/etc/profile.d/nix-daemon.sh ]] ||
      diene_die GuestNixIdentityUnexpected \
        'the exact guest Nix profile does not resolve into the pinned Nix store'
  fi
  set +eu
  # shellcheck disable=SC1090
  source "$profile"
  profile_rc=$?
  set -eu
  set -o pipefail
  ((profile_rc == 0)) ||
    diene_die GuestNixProfileSourceFailed \
      'the exact guest Nix profile returned nonzero while being sourced'
}

# Verify the installed toolchain through literal paths supplied by the caller,
# write one canonical mode-0600 identity receipt, and print the same object plus
# the receipt digest for embedding in preflight evidence. Tests may pass an
# isolated store root; the production caller supplies the fixed /nix paths.
diene_guest_nix_identity() {
  local input=${1:?driver inputs required} evidence_dir=${2:?guest Nix evidence directory required}
  local nix_bin=${3:?direct Nix binary required} store_root=${4:?Nix store root required}
  local installed_copy=${5:?installed installer copy required}
  local bootstrap_asset=${6:?provenance shell asset required}
  local payload_asset=${7:?installer payload asset required} observed_arch=${8:?observed architecture required}
  local test_root=${9:-}
  local contract expected_nix expected_installer live_version live_stderr recorded_version recorded_stderr
  local recorded_installer recorded_installer_stderr expected_bytes store_path store_digest
  local installed_copy_digest environment_file environment_digest nix_config nix_config_digest
  local bootstrap_digest payload_digest identity receipt receipt_digest
  local LC_ALL=C

  contract=$(diene_guest_nix_contract) || exit $?
  jq -e --argjson contract "$contract" '.guestNix == $contract' "$input" >/dev/null ||
    diene_die GuestNixIdentityUnexpected 'admitted guest Nix contract differs from the fixed contract'
  [[ $observed_arch == "$(jq -r '.architecture' <<<"$contract")" ]] ||
    diene_die GuestNixIdentityUnexpected 'guest Nix architecture changed after installation'
  [[ $nix_bin == "$test_root$(jq -r '.nixBinPath' <<<"$contract")" &&
    $store_root == "$test_root$(jq -r '.storeRoot' <<<"$contract")" &&
    $installed_copy == "$test_root$(jq -r '.installedCopyPath' <<<"$contract")" ]] ||
    diene_die GuestNixIdentityUnexpected 'guest Nix identity paths differ from the admitted contract'
  [[ -d $evidence_dir && ! -L $evidence_dir ]] ||
    diene_die GuestNixIdentityUnexpected 'guest Nix evidence directory is unavailable'
  environment_file="$evidence_dir/environment.txt"
  nix_config="$test_root/etc/nix/nix.conf"
  [[ -f $environment_file && ! -L $environment_file &&
    $(stat -c %a -- "$environment_file") == 600 ]] ||
    diene_die GuestNixIdentityUnexpected \
      'the guest Nix environment evidence is absent, linked, or not mode 0600'
  [[ -f $nix_config && ! -L $nix_config && -r $nix_config ]] ||
    diene_die GuestNixIdentityUnexpected \
      'the installed Nix configuration is absent, linked, or unreadable'
  nix_config_digest=$(diene_file_digest "$nix_config")
  LC_ALL=C awk -v config="${nix_config_digest#sha256:}" '
    { line[NR]=$0 }
    END {
      if (NR < 5 || line[1] != "inheritedNixFamily=none" ||
          line[NR-3] != "home=/run/diene-ci/home" ||
          line[NR-2] != "xdgConfigHome=/run/diene-ci/home/.config" ||
          line[NR-1] != "userConfFiles=/run/diene-ci/nix-user.conf" ||
          line[NR] != "etcNixConf=" config) exit 1
      previous=""
      for (i=2; i<=NR-4; i++) {
        if (line[i] !~ /^profileNixVar=NIX[A-Za-z0-9_]*$/ ||
            (previous != "" && line[i] <= previous)) exit 1
        previous=line[i]
      }
    }
  ' "$environment_file" ||
    diene_die GuestNixIdentityUnexpected \
      'the guest Nix environment evidence fields or profile-created names are invalid'
  environment_digest=$(diene_file_digest "$environment_file")
  [[ -x $nix_bin ]] ||
    diene_die GuestNixIdentityUnexpected 'the direct installed Nix binary is absent or not executable'

  live_version="$evidence_dir/live-version.txt"
  live_stderr="$evidence_dir/live-version.stderr"
  : >"$live_version"
  : >"$live_stderr"
  chmod 0600 "$live_version" "$live_stderr"
  if ! "$nix_bin" --version >"$live_version" 2>"$live_stderr"; then
    diene_die GuestNixIdentityUnexpected 'the direct installed Nix identity command failed'
  fi
  expected_nix=$(jq -r '.nixVersion' <<<"$contract")
  expected_bytes=$((${#expected_nix} + 1))
  if [[ -s $live_stderr || $(wc -c <"$live_version") != "$expected_bytes" ]] ||
    ! grep -Fxq -- "$expected_nix" "$live_version"; then
    diene_die GuestNixIdentityUnexpected 'the direct installed Nix identity is not the exact pinned line'
  fi

  recorded_version="$evidence_dir/version.txt"
  if [[ ! -f $recorded_version || -L $recorded_version ]] ||
    ! cmp -s -- "$recorded_version" "$live_version"; then
    diene_die GuestNixIdentityUnexpected 'recorded and live guest Nix identities disagree'
  fi
  recorded_stderr="$evidence_dir/version.stderr"
  [[ -f $recorded_stderr && ! -L $recorded_stderr && ! -s $recorded_stderr ]] ||
    diene_die GuestNixIdentityUnexpected 'the recorded guest Nix identity emitted unexpected stderr'
  recorded_installer="$evidence_dir/installer-version.txt"
  expected_installer=$(jq -r '.installerVersion' <<<"$contract")
  expected_bytes=$((${#expected_installer} + 1))
  if [[ ! -f $recorded_installer || -L $recorded_installer ||
    $(wc -c <"$recorded_installer") != "$expected_bytes" ]] ||
    ! grep -Fxq -- "$expected_installer" "$recorded_installer"; then
    diene_die GuestNixIdentityUnexpected 'recorded guest Nix installer identity disagrees with the pin'
  fi
  recorded_installer_stderr="$evidence_dir/installer-version.stderr"
  [[ -f $recorded_installer_stderr && ! -L $recorded_installer_stderr &&
    ! -s $recorded_installer_stderr ]] ||
    diene_die GuestNixIdentityUnexpected \
      'the recorded guest Nix installer identity emitted unexpected stderr'

  if ! store_path=$(readlink -f -- "$nix_bin"); then
    diene_die GuestNixIdentityUnexpected 'the direct installed Nix binary cannot be resolved'
  fi
  case $store_path in
    "$store_root"/*/bin/nix) ;;
    *) diene_die GuestNixIdentityUnexpected 'the direct installed Nix binary does not resolve into the store' ;;
  esac
  [[ -f $store_path && ! -L $store_path && -x $store_path ]] ||
    diene_die GuestNixIdentityUnexpected 'the resolved Nix store target is not a regular executable'
  [[ -f $installed_copy && ! -L $installed_copy && -f $bootstrap_asset && ! -L $bootstrap_asset &&
    -f $payload_asset && ! -L $payload_asset ]] ||
    diene_die GuestNixIdentityUnexpected 'a guest Nix installer or uploaded artifact is absent'
  store_digest=$(diene_file_digest "$store_path")
  installed_copy_digest=$(diene_file_digest "$installed_copy")
  bootstrap_digest=$(diene_file_digest "$bootstrap_asset")
  payload_digest=$(diene_file_digest "$payload_asset")
  [[ $bootstrap_digest == "$(jq -r '.installerDigest' <<<"$contract")" &&
    $payload_digest == "$(jq -r '.payloadDigest' <<<"$contract")" ]] ||
    diene_die GuestNixIdentityUnexpected 'uploaded guest Nix artifacts changed after installation'
  [[ $(stat -c %a -- "$bootstrap_asset") == 600 ]] ||
    diene_die GuestNixIdentityUnexpected 'the provenance shell witness gained execute permission'
  [[ $installed_copy_digest == "$(jq -r '.payloadDigest' <<<"$contract")" ]] ||
    diene_die GuestNixIdentityUnexpected 'the installed Nix installer copy does not match the pinned payload'

  identity=$(jq -Scn --argjson contract "$contract" --arg storePath "$store_path" \
    --arg storePathDigest "$store_digest" --arg installedCopyDigest "$installed_copy_digest" \
    --arg environmentDigest "$environment_digest" '
    $contract + {storePath:$storePath,storePathDigest:$storePathDigest,
      installedCopyDigest:$installedCopyDigest,environmentDigest:$environmentDigest,
      profileSourced:true}')
  receipt="$evidence_dir/identity.json"
  printf '%s\n' "$identity" | diene_write_json "$receipt"
  receipt_digest=$(diene_file_digest "$receipt")
  jq -c --arg digest "$receipt_digest" '. + {identityReceiptDigest:$digest}' "$receipt"
}

diene_require_guest_nix_preflight_agreement() {
  local preflight=${1:?preflight evidence required} receipt=${2:?identity receipt required}
  local receipt_digest environment environment_digest
  [[ -f $preflight && ! -L $preflight && -f $receipt && ! -L $receipt ]] ||
    diene_die GuestNixIdentityUnexpected 'guest Nix preflight or identity receipt is absent'
  environment="$(dirname -- "$receipt")/environment.txt"
  [[ -f $environment && ! -L $environment && $(stat -c %a -- "$environment") == 600 ]] ||
    diene_die GuestNixIdentityUnexpected \
      'guest Nix environment evidence is absent, linked, or not mode 0600'
  receipt_digest=$(diene_file_digest "$receipt")
  environment_digest=$(diene_file_digest "$environment")
  jq -e --arg digest "$receipt_digest" --arg environmentDigest "$environment_digest" \
    --slurpfile identity "$receipt" '
    (.guestNix | del(.identityReceiptDigest)) == $identity[0] and
    .guestNix.identityReceiptDigest == $digest and
    $identity[0].environmentDigest == $environmentDigest
  ' "$preflight" >/dev/null ||
    diene_die GuestNixIdentityUnexpected \
      'guest Nix identity receipt and preflight evidence do not agree exactly'
}

diene_guest_toolchain_evidence_dir() {
  local staging=${DIENE_EVIDENCE_STAGING:-} dir
  [[ $staging == /* && -d $staging && ! -L $staging && ${staging##*/} == staging ]] ||
    diene_die GuestToolchainIdentityUnexpected \
      'guest toolchain identity requires an absolute driver-owned evidence staging directory'
  dir="${staging%/staging}/gnu-toolchain"
  [[ ! -L $dir ]] ||
    diene_die GuestToolchainIdentityUnexpected 'guest toolchain evidence directory is a symlink'
  install -d -m 0700 "$dir" ||
    diene_die GuestToolchainIdentityUnexpected 'guest toolchain evidence directory could not be created'
  [[ -d $dir && ! -L $dir ]] ||
    diene_die GuestToolchainIdentityUnexpected \
      'guest toolchain evidence directory is not a real directory'
  printf '%s\n' "$dir"
}

# Independently re-prove the system toolchain through literal /usr/bin paths.
# An optional test root prefixes those paths without changing the admitted
# production contract or the logical paths recorded in evidence.
diene_guest_toolchain_identity() {
  local input=${1:?driver inputs required}
  local evidence_dir=${2:?guest toolchain evidence directory required}
  local test_root=${3:-}
  local contract contract_digest root_path readlink_bin grep_bin sha256_bin sed_bin tar_bin
  local name binary logical_expected token binary_path resolved logical_resolved stdout_file stderr_file
  local pins_file install_log stage_identity expected_pins expected_identity identity_lines=''
  local scratch sha_stdout sha_stderr sed_stdout sed_stderr tar_stdout tar_stderr
  local tar_resolved tar_listing tar_types tar_type identity receipt receipt_digest
  local pins_digest install_log_digest stage_identity_digest
  local LC_ALL=C

  contract=$(diene_guest_toolchain_contract) || exit $?
  contract_digest=$(diene_guest_toolchain_contract_digest) || exit $?
  jq -e --argjson contract "$contract" '.guestToolchain == $contract' "$input" >/dev/null ||
    diene_die GuestToolchainIdentityUnexpected \
      'admitted guest toolchain contract differs from the fixed contract'
  if [[ -n $test_root ]]; then
    [[ $test_root == /* && -d $test_root && ! -L $test_root ]] ||
      diene_die InputContractInvalid 'the fake guest toolchain root is not a safe absolute directory'
    root_path=${test_root%/}
  else
    root_path=
  fi
  [[ -d $evidence_dir && ! -L $evidence_dir ]] ||
    diene_die GuestToolchainIdentityUnexpected 'guest toolchain evidence directory is unavailable'

  pins_file="$evidence_dir/pins.txt"
  install_log="$evidence_dir/install.log"
  stage_identity="$evidence_dir/identity.txt"
  for binary_path in "$pins_file" "$install_log" "$stage_identity"; do
    [[ -f $binary_path && ! -L $binary_path && $(stat -c %a -- "$binary_path") == 600 ]] ||
      diene_die GuestToolchainIdentityUnexpected \
        'guest toolchain stage evidence is absent, linked, or not mode 0600'
  done
  expected_pins="executionMode=$DIENE_GUEST_TOOLCHAIN_EXECUTION_MODE"
  while IFS='|' read -r name binary logical_expected token; do
    expected_pins="$expected_pins
$name $binary $logical_expected $token"
  done <<<"$DIENE_GUEST_TOOLCHAIN_PACKAGES"
  [[ $(wc -l <"$pins_file") == 11 && $(wc -c <"$pins_file") == $((${#expected_pins} + 1)) &&
    $(cat "$pins_file") == "$expected_pins" ]] ||
    diene_die GuestToolchainIdentityUnexpected \
      'guest toolchain pin evidence differs from the admitted fixed closure'

  readlink_bin="$root_path/usr/bin/readlink"
  grep_bin="$root_path/usr/bin/grep"
  sha256_bin="$root_path/usr/bin/sha256sum"
  sed_bin="$root_path/usr/bin/sed"
  tar_bin="$root_path/usr/bin/tar"
  for binary_path in "$readlink_bin" "$grep_bin" "$sha256_bin" "$sed_bin" "$tar_bin"; do
    [[ -x $binary_path ]] ||
      diene_die GuestToolchainIdentityUnexpected \
        'a required absolute-path guest toolchain proof binary is absent or not executable'
  done

  while IFS='|' read -r name binary logical_expected token; do
    token="$token "
    binary_path="$root_path$binary"
    [[ -x $binary_path ]] ||
      diene_die GuestToolchainIdentityUnexpected \
        "the absolute-path guest toolchain binary $binary is absent or not executable"
    resolved=$($readlink_bin -f -- "$binary_path" 2>/dev/null) ||
      diene_die GuestToolchainIdentityUnexpected \
        "the absolute-path guest toolchain binary $binary cannot be resolved"
    [[ $resolved == "$root_path$logical_expected" && $resolved != */busybox ]] ||
      diene_die GuestToolchainIdentityUnexpected \
        "the absolute-path guest toolchain binary $binary resolved unexpectedly"
    logical_resolved=${resolved#"$root_path"}
    stdout_file="$evidence_dir/$name-version.txt"
    stderr_file="$evidence_dir/$name-version.stderr"
    : >"$stdout_file"
    : >"$stderr_file"
    chmod 0600 "$stdout_file" "$stderr_file"
    if ! "$binary_path" --version >"$stdout_file" 2>"$stderr_file"; then
      diene_die GuestToolchainIdentityUnexpected \
        "the absolute-path guest toolchain identity probe for $name failed"
    fi
    if [[ -s $stderr_file ]] || ! "$grep_bin" -Fq -- "$token" "$stdout_file"; then
      diene_die GuestToolchainIdentityUnexpected \
        "the absolute-path guest toolchain identity for $name lacks its fixed GNU token"
    fi
    identity_lines="$identity_lines$name|$binary|$logical_resolved|$token
"
  done <<'GUEST_TOOLCHAIN_IDENTITIES'
sed|/usr/bin/sed|/usr/bin/sed|(GNU sed)
grep|/usr/bin/grep|/usr/bin/grep|(GNU grep)
awk|/usr/bin/awk|/usr/bin/gawk|GNU Awk
find|/usr/bin/find|/usr/bin/find|(GNU findutils)
xargs|/usr/bin/xargs|/usr/bin/xargs|(GNU findutils)
sha256sum|/usr/bin/sha256sum|/usr/bin/coreutils|(GNU coreutils)
stat|/usr/bin/stat|/usr/bin/coreutils|(GNU coreutils)
cut|/usr/bin/cut|/usr/bin/coreutils|(GNU coreutils)
sort|/usr/bin/sort|/usr/bin/coreutils|(GNU coreutils)
head|/usr/bin/head|/usr/bin/coreutils|(GNU coreutils)
wc|/usr/bin/wc|/usr/bin/coreutils|(GNU coreutils)
date|/usr/bin/date|/usr/bin/coreutils|(GNU coreutils)
tr|/usr/bin/tr|/usr/bin/coreutils|(GNU coreutils)
cat|/usr/bin/cat|/usr/bin/coreutils|(GNU coreutils)
install|/usr/bin/install|/usr/bin/coreutils|(GNU coreutils)
readlink|/usr/bin/readlink|/usr/bin/coreutils|(GNU coreutils)
id|/usr/bin/id|/usr/bin/coreutils|(GNU coreutils)
mktemp|/usr/bin/mktemp|/usr/bin/coreutils|(GNU coreutils)
chmod|/usr/bin/chmod|/usr/bin/coreutils|(GNU coreutils)
rm|/usr/bin/rm|/usr/bin/coreutils|(GNU coreutils)
uname|/usr/bin/uname|/usr/bin/coreutils|(GNU coreutils)
GUEST_TOOLCHAIN_IDENTITIES

  scratch=$(mktemp -d "$evidence_dir/.identity-proof.XXXXXX") ||
    diene_die GuestToolchainIdentityUnexpected 'guest toolchain behavior scratch directory cannot be created'
  chmod 0700 "$scratch"
  printf '%s\n' diene-gnu-toolchain >"$scratch/known.txt"
  printf '%s  %s\n' c28908b77b6613d7f8595ab582fa4bbf7042b8fbb163625ab3522f79a8dc88a9 known.txt \
    >"$scratch/known.sha256"
  sha_stdout="$scratch/sha256.stdout"
  sha_stderr="$scratch/sha256.stderr"
  if ! (cd "$scratch" && "$sha256_bin" --check known.sha256 >"$sha_stdout" 2>"$sha_stderr") ||
    [[ -s $sha_stderr ]] || ! "$grep_bin" -Fxq -- 'known.txt: OK' "$sha_stdout"; then
    rm -rf -- "$scratch"
    diene_die GuestToolchainIdentityUnexpected \
      'GNU sha256sum --check did not verify the fixed known-byte behavior probe'
  fi
  printf '%s\n' a >"$scratch/sed.txt"
  sed_stdout="$scratch/sed.stdout"
  sed_stderr="$scratch/sed.stderr"
  if ! "$sed_bin" -i 's/a/b/' "$scratch/sed.txt" >"$sed_stdout" 2>"$sed_stderr" ||
    [[ -s $sed_stdout || -s $sed_stderr ]] || ! "$grep_bin" -Fxq -- b "$scratch/sed.txt"; then
    rm -rf -- "$scratch"
    diene_die GuestToolchainIdentityUnexpected \
      'GNU sed -i did not perform the fixed in-place behavior probe'
  fi

  tar_resolved=$($readlink_bin -f -- "$tar_bin" 2>/dev/null) || {
    rm -rf -- "$scratch"
    diene_die GuestToolchainTarUnexpected 'the absolute-path guest tar cannot be resolved'
  }
  [[ $tar_resolved == "$root_path/usr/bin/busybox" ]] || {
    rm -rf -- "$scratch"
    diene_die GuestToolchainTarUnexpected 'the guest tar implementation is not the fixed BusyBox binary'
  }
  install -d -m 0700 "$scratch/tar-source" "$scratch/tar-output"
  printf '%s\n' portable >"$scratch/tar-source/member"
  tar_stdout="$scratch/tar.stdout"
  tar_stderr="$scratch/tar.stderr"
  : >"$tar_stdout"
  : >"$tar_stderr"
  if ! "$tar_bin" -cf "$scratch/probe.tar" -C "$scratch/tar-source" member \
      >>"$tar_stdout" 2>>"$tar_stderr" ||
    ! tar_listing=$("$tar_bin" -tf "$scratch/probe.tar" 2>>"$tar_stderr") ||
    ! tar_types=$("$tar_bin" -tvf "$scratch/probe.tar" 2>>"$tar_stderr") ||
    ! "$tar_bin" -xf "$scratch/probe.tar" -C "$scratch/tar-output" \
      >>"$tar_stdout" 2>>"$tar_stderr" || [[ -s $tar_stderr ]] ||
    [[ $tar_listing != member || ! -f $scratch/tar-output/member ]] ||
    ! "$grep_bin" -Fxq -- portable "$scratch/tar-output/member"; then
    rm -rf -- "$scratch"
    diene_die GuestToolchainTarUnexpected \
      'the BusyBox tar portable -cf/-tf/-tvf/-xf/-C/-f behavior probe failed'
  fi
  tar_type=${tar_types:0:1}
  [[ $tar_type == - ]] || {
    rm -rf -- "$scratch"
    diene_die GuestToolchainTarUnexpected \
      'the BusyBox tar verbose listing did not identify a regular member with a dash'
  }
  rm -rf -- "$scratch"
  identity_lines="${identity_lines}behaviorSha256sumCheck=pass
behaviorSedInPlace=pass
tarImplementation=busybox
tarResolvedPath=/usr/bin/busybox
tarPortableFlags=-cf,-tf,-tvf,-xf,-C,-f
tarTypeCharacter=-"
  expected_identity=$identity_lines
  [[ $(wc -c <"$stage_identity") == $((${#expected_identity} + 1)) &&
    $(cat "$stage_identity") == "$expected_identity" ]] ||
    diene_die GuestToolchainIdentityUnexpected \
      'stage-0 guest toolchain identity evidence disagrees with the independent proof'

  pins_digest=$(diene_file_digest "$pins_file")
  install_log_digest=$(diene_file_digest "$install_log")
  stage_identity_digest=$(diene_file_digest "$stage_identity")
  identity=$(jq -Scn --argjson contract "$contract" --arg contractDigest "$contract_digest" \
    --arg pinsDigest "$pins_digest" --arg installLogDigest "$install_log_digest" \
    --arg stageIdentityDigest "$stage_identity_digest" '
    $contract + {contractDigest:$contractDigest,absolutePathIdentity:true,
      sha256sumCheckBehavior:true,sedInPlaceBehavior:true,tarImplementation:"busybox",
      tarResolvedPath:"/usr/bin/busybox",tarPortableFlags:["-cf","-tf","-tvf","-xf","-C","-f"],
      tarTypeCharacter:"-",pinsDigest:$pinsDigest,installLogDigest:$installLogDigest,
      stageIdentityDigest:$stageIdentityDigest}')
  receipt="$evidence_dir/identity.json"
  printf '%s\n' "$identity" | diene_write_json "$receipt"
  receipt_digest=$(diene_file_digest "$receipt")
  jq -c --arg digest "$receipt_digest" '. + {identityReceiptDigest:$digest}' "$receipt"
}

diene_require_guest_toolchain_preflight_agreement() {
  local preflight=${1:?preflight evidence required} receipt=${2:?identity receipt required}
  local receipt_digest pins install_log stage_identity evidence
  [[ -f $preflight && ! -L $preflight && -f $receipt && ! -L $receipt ]] ||
    diene_die GuestToolchainIdentityUnexpected \
      'guest toolchain preflight or identity receipt is absent'
  pins="$(dirname -- "$receipt")/pins.txt"
  install_log="$(dirname -- "$receipt")/install.log"
  stage_identity="$(dirname -- "$receipt")/identity.txt"
  for evidence in "$pins" "$install_log" "$stage_identity"; do
    [[ -f $evidence && ! -L $evidence && $(stat -c %a -- "$evidence") == 600 ]] ||
      diene_die GuestToolchainIdentityUnexpected \
        'guest toolchain bound stage evidence is absent, linked, or not mode 0600'
  done
  receipt_digest=$(diene_file_digest "$receipt")
  jq -e --arg digest "$receipt_digest" \
    --arg pinsDigest "$(diene_file_digest "$pins")" \
    --arg installLogDigest "$(diene_file_digest "$install_log")" \
    --arg stageIdentityDigest "$(diene_file_digest "$stage_identity")" \
    --slurpfile identity "$receipt" '
    (.guestToolchain | del(.identityReceiptDigest)) == $identity[0] and
    .guestToolchain.identityReceiptDigest == $digest and
    $identity[0].pinsDigest == $pinsDigest and
    $identity[0].installLogDigest == $installLogDigest and
    $identity[0].stageIdentityDigest == $stageIdentityDigest
  ' "$preflight" >/dev/null ||
    diene_die GuestToolchainIdentityUnexpected \
      'guest toolchain identity receipt and preflight evidence do not agree exactly'
}

diene_archive_is_safe() {
  local archive=${1:?archive required}
  local required_root=${2:-}
  [[ -f $archive && ! -L $archive ]] || return 1

  local listing types name_count type_count
  listing=$(mktemp "${RUNNER_TEMP:-/tmp}/diene-archive-list.XXXXXX") || return 1
  types=$(mktemp "${RUNNER_TEMP:-/tmp}/diene-archive-types.XXXXXX") || {
    rm -f -- "$listing"
    return 1
  }
  if ! LC_ALL=C tar --list --quoting-style=escape --file "$archive" >"$listing"; then
    rm -f -- "$listing" "$types"
    return 1
  fi
  if ! LC_ALL=C tar --list --verbose --numeric-owner --quoting-style=escape \
    --file "$archive" >"$types"; then
    rm -f -- "$listing" "$types"
    return 1
  fi

  name_count=$(wc -l <"$listing")
  type_count=$(wc -l <"$types")
  if [[ $name_count == 0 || $name_count != "$type_count" ]] ||
    ! LC_ALL=C awk -v root="$required_root" '
      function unsafe(name, normalized, escaped) {
        # GNU tar escape quoting renders UTF-8 bytes as octal sequences. Allow
        # non-ASCII byte escapes, but reject named/control escapes, encoded
        # ASCII separators, and literal backslashes. Thus canonical names such
        # as the lightning workflow survive without making newline or \057 a
        # hidden path separator.
        escaped = name
        while (match(escaped, /\\[23][0-7][0-7]/))
          escaped = substr(escaped, 1, RSTART - 1) "U" substr(escaped, RSTART + RLENGTH)
        if (escaped ~ /\\/) return 1
        if (name == "" || name ~ /^\// || name ~ /\/\//) return 1
        normalized = name
        sub(/\/$/, "", normalized)
        if (normalized == "" || normalized == "." ||
            normalized ~ /(^|\/)\.\.?(\/|$)/) return 1
        if (root != "" && normalized != root && index(normalized, root "/") != 1) return 1
        if (seen[normalized]++) return 1
        return 0
      }
      unsafe($0) { bad=1 }
      END { exit bad ? 1 : 0 }
    ' "$listing" ||
    ! LC_ALL=C awk '
      substr($0, 1, 1) != "-" && substr($0, 1, 1) != "d" { bad=1 }
      END { exit bad ? 1 : 0 }
    ' "$types"; then
    rm -f -- "$listing" "$types"
    return 1
  fi
  rm -f -- "$listing" "$types"
}

diene_tree_is_safe() {
  local root=${1:?tree root required}
  [[ -d $root && ! -L $root && -r $root && -x $root ]] || return 1
  local manifest path safe=true
  manifest=$(mktemp "${RUNNER_TEMP:-/tmp}/diene-tree.XXXXXX") || return 1
  if ! find "$root" -print0 >"$manifest"; then
    rm -f -- "$manifest"
    return 1
  fi
  while IFS= read -r -d '' path; do
    if [[ -L $path ]]; then
      safe=false
      break
    elif [[ -f $path ]]; then
      [[ -r $path ]] || { safe=false; break; }
    elif [[ -d $path ]]; then
      [[ -r $path && -x $path ]] || { safe=false; break; }
    else
      safe=false
      break
    fi
  done <"$manifest"
  rm -f -- "$manifest"
  [[ $safe == true ]]
}

diene_require_archive_members() {
  local archive=${1:?archive required}
  shift
  (($# > 0)) || diene_die InputContractInvalid 'at least one required archive member must be declared'
  diene_archive_is_safe "$archive" ||
    diene_die UntrustedSubject \
      'source archive has an unsafe name, duplicate, link, device, FIFO, socket, or other special member'
  local listing member
  listing=$(mktemp "${RUNNER_TEMP:-/tmp}/diene-archive-list.XXXXXX") ||
    diene_die UntrustedSubject 'could not allocate a source archive listing'
  if ! LC_ALL=C tar --list --quoting-style=escape --file "$archive" >"$listing"; then
    rm -f -- "$listing"
    diene_die UntrustedSubject 'source archive could not be listed completely'
  fi
  for member in "$@"; do
    if ! grep -Fx -- "$member" "$listing" >/dev/null; then
      rm -f -- "$listing"
      diene_die UntrustedSubject "source archive does not carry required member $member"
    fi
  done
  rm -f -- "$listing"
}

# ---------------------------------------------------------------------------
# JSON Schema validation.
# ---------------------------------------------------------------------------

diene_schema_dir() {
  local dir=${DIENE_SCHEMA_DIR:-schemas/ci}
  [[ -d $dir ]] || diene_die InputContractInvalid "schema directory $dir is absent"
  (cd -- "$dir" && pwd)
}

diene_schema_validate() {
  local schema_name=${1:?schema required}
  local document=${2:?document required}
  local label=${3:-$document}
  local validator=${DIENE_SCHEMA_VALIDATOR_BIN:-check-jsonschema}
  diene_require_command "$validator"
  [[ -f $document ]] || diene_die SchemaValidationFailed "$label is absent"
  local dir schema
  dir=$(diene_schema_dir)
  schema="$dir/$schema_name"
  [[ -f $schema ]] || diene_die SchemaValidationFailed "schema $schema_name is absent"
  "$validator" --base-uri "file://$dir/" --schemafile "$schema" "$document" >/dev/null ||
    diene_die SchemaValidationFailed "$label does not satisfy $schema_name"
}

# ---------------------------------------------------------------------------
# Stable lane identity and trusted input contract.
# ---------------------------------------------------------------------------

diene_runtime_profile() {
  case ${1:?lane required} in
    ditto-build-local | ditto-target-pull | ditto-vendor | fleet-independence) printf 'ditto\n' ;;
    absol) printf 'absol\n' ;;
    *) diene_die InputContractInvalid "unknown lane $1" ;;
  esac
}

diene_build_mode() {
  case ${1:?lane required} in
    ditto-target-pull) printf 'target-pull\n' ;;
    ditto-build-local | ditto-vendor | fleet-independence | absol) printf 'build-local\n' ;;
    *) diene_die InputContractInvalid "unknown lane $1" ;;
  esac
}

diene_egress_profile() {
  case ${1:?lane required} in
    ditto-build-local) printf 'ditto-build-local-v1\n' ;;
    ditto-target-pull) printf 'ditto-target-pull-v1\n' ;;
    ditto-vendor) printf 'ditto-vendor-v1\n' ;;
    absol) printf 'absol-hermetic-v1\n' ;;
    fleet-independence) printf 'fleet-independence-v1\n' ;;
    *) diene_die InputContractInvalid "unknown lane $1" ;;
  esac
}

diene_allocation_key() {
  local lane=${DIENE_LANE:?lane required}
  local key="r${GITHUB_REPOSITORY_ID}-w${GITHUB_RUN_ID}-a${GITHUB_RUN_ATTEMPT}-l${lane}"
  if [[ $lane == ditto-vendor ]]; then
    key="${key}-v${DIENE_ACTION_ID:?action id required}"
  fi
  printf '%s\n' "$key"
}

diene_generation_key() {
  printf 'g%s\n' "${GITHUB_SHA:0:12}"
}

diene_receipt_id() {
  printf '%s-%s\n' "$(diene_allocation_key)" "$(diene_generation_key)"
}

diene_runtime_dir() {
  [[ ${RUNNER_TEMP:-} == /* ]] || diene_die InstancePostureUnavailable 'RUNNER_TEMP must be absolute'
  local dir
  dir="$RUNNER_TEMP/diene/$(diene_allocation_key)-$(diene_generation_key)"
  install -d -m 0700 "$dir"
  printf '%s\n' "$dir"
}

diene_require_trusted_runtime_context() {
  [[ ${DIENE_TRUSTED_RUNTIME_CONTEXT:-} == protected-base ]] ||
    diene_die UntrustedSubject \
      'the interim in-guest policy is allowed only for a protected base-owned workflow; untrusted content must refuse before nsc create'
}

diene_refuse_forbidden_runtime_inputs() {
  [[ ${DIENE_NSC_DURATION:-2h} == 2h ]] ||
    diene_die InputContractInvalid 'production SIT duration is exactly 2h'
  [[ -z ${DIENE_NAMESPACE_INGRESS:-} && -z ${DIENE_PUBLIC_ENDPOINT:-} ]] ||
    diene_die InputContractInvalid 'Namespace ingress and public endpoints are forbidden'
  case ${DIENE_LANE:?} in
    absol | fleet-independence)
      [[ -z ${DIENE_NSC_CACHE_TAG:-} && -z ${DIENE_CACHE_DIR:-} ]] ||
        diene_die InputContractInvalid "$DIENE_LANE forbids every shared cache attachment"
      [[ -z ${DIENE_SEED_IDENTITY:-} && -z ${DIENE_VENDOR_CREDENTIAL:-} ]] ||
        diene_die InputContractInvalid "$DIENE_LANE forbids seed and vendor credentials"
      ;;
  esac
}

# Validate and select the exact core journey tuple once for both the pre-create
# contract gate and the credential-free driver. When an output path is supplied
# the selected entries are written as JSONL; validation-only callers stay silent.
diene_select_journeys() {
  local manifest=${1:?journey manifest required}
  local output=${2:-}
  [[ -f $manifest && ! -L $manifest ]] ||
    diene_die InputContractInvalid 'journey manifest is absent or not a regular file'
  diene_schema_validate diene-journeys-v1.schema.json "$manifest" 'journey manifest'
  jq -e '[.journeys[].id] | length == (unique | length)' "$manifest" >/dev/null ||
    diene_die InputContractInvalid 'journey IDs must be globally unique'

  local lane=${DIENE_LANE:?lane required} profile build_mode fixture selection
  [[ $lane != ditto-vendor ]] ||
    diene_die InputContractInvalid 'vendor lane has no core journey selector'
  profile=$(diene_runtime_profile "$lane")
  build_mode=$(diene_build_mode "$lane")
  fixture=${DIENE_FIXTURE_ID:-}
  selection=$(jq -c --arg lane "$lane" --arg profile "$profile" \
    --arg mode "$build_mode" --arg fixture "$fixture" '
      .journeys[] | select(any(.appliesTo[];
        .lane == $lane and .profile == $profile and .buildMode == $mode and
        ((.fixtureId // "") == $fixture)))
    ' "$manifest") || diene_die InputContractInvalid 'journey selection could not be evaluated'
  [[ -n $selection ]] ||
    diene_die JourneySelectorUnsatisfied \
      "journey manifest has no declaration for $lane/$profile/$build_mode/${fixture:-<none>}"
  if [[ -n $output ]]; then
    printf '%s\n' "$selection" | diene_write_json "$output"
  fi
}

diene_validate_inputs() {
  local lane=${DIENE_LANE:-}
  local repository_id=${GITHUB_REPOSITORY_ID:-}
  local repository_key=${GITHUB_REPOSITORY:-}
  [[ $repository_id =~ ^[1-9][0-9]*$ ]] || diene_die InputContractInvalid 'repository_id must be immutable numeric ID'
  [[ $repository_key =~ ^AtomiCloud/[A-Za-z0-9_.-]+$ ]] ||
    diene_die InputContractInvalid 'repository_key must be canonical AtomiCloud key'
  [[ ${GITHUB_RUN_ID:-} =~ ^[1-9][0-9]*$ && ${GITHUB_RUN_ATTEMPT:-} =~ ^[1-9][0-9]*$ ]] ||
    diene_die InputContractInvalid 'run ID and attempt must be positive integers'
  diene_require_full_sha source_sha "${GITHUB_SHA:-}"
  diene_require_digest garden_lock_digest "${DIENE_GARDEN_LOCK_DIGEST:-}"
  diene_require_digest artifact_digest "${DIENE_ARTIFACT_DIGEST:-}"
  diene_require_trusted_runtime_context
  diene_refuse_forbidden_runtime_inputs

  local workflow_ref=${DIENE_BASE_WORKFLOW_REF:-}
  [[ $workflow_ref =~ ^${repository_key}/\.github/workflows/[^@]+@[0-9a-f]{40}$ ]] ||
    diene_die UntrustedSubject 'base workflow ref must be this repository at a full commit'
  [[ ${workflow_ref##*@} == "$GITHUB_SHA" ]] ||
    diene_die UntrustedSubject 'base workflow ref does not bind source_sha'

  diene_load_subject

  case $lane in
    ditto-build-local | ditto-target-pull | absol | fleet-independence)
      [[ ${DIENE_JOURNEY_MANIFEST:-} == .diene/ci/journeys.v1.yaml ]] ||
        diene_die InputContractInvalid 'journey_manifest must be the canonical path'
      [[ -z ${DIENE_VENDOR_MANIFEST:-} && -z ${DIENE_ACTION_ID:-} ]] ||
        diene_die InputContractInvalid 'core lanes forbid vendor selectors'
      ;;
    ditto-vendor)
      [[ -z ${DIENE_JOURNEY_MANIFEST:-} ]] || diene_die InputContractInvalid 'vendor lane forbids journey_manifest'
      [[ ${DIENE_VENDOR_MANIFEST:-} == .diene/ci/vendors.v1.yaml ]] ||
        diene_die InputContractInvalid 'vendor_manifest must be the canonical path'
      [[ ${DIENE_ACTION_ID:-} =~ ^[a-z0-9][a-z0-9-]{0,127}$ ]] ||
        diene_die InputContractInvalid 'action_id is not a safe declared identifier'
      [[ -z ${DIENE_FIXTURE_ID:-} ]] || diene_die InputContractInvalid 'vendor lane forbids fixture selector'
      ;;
    *) diene_die InputContractInvalid "unknown lane $lane" ;;
  esac

  if [[ $lane == ditto-target-pull ]]; then
    diene_require_digest artifact_attestation_digest "${DIENE_ARTIFACT_ATTESTATION_DIGEST:-}"
    [[ -n ${DIENE_ARTIFACT_PROVENANCE_REF:-} ]] ||
      diene_die InputContractInvalid 'target-pull requires the published provenance reference'
    [[ $DIENE_ARTIFACT_PROVENANCE_REF == "$DIENE_SUBJECT_PROVENANCE_REF" ]] ||
      diene_die UntrustedSubject 'artifact_provenance_ref does not match the published provenance'
    [[ $DIENE_ARTIFACT_ATTESTATION_DIGEST == "$DIENE_SUBJECT_ATTESTATION_DIGEST" ]] ||
      diene_die UntrustedSubject 'artifact_attestation_digest does not match the published attestation'
    [[ -n ${DIENE_SUBJECT_PULL_IDENTITY:-} && $DIENE_SUBJECT_PULL_IDENTITY != "$DIENE_SUBJECT_PRODUCER_WORKFLOW_REF" ]] ||
      diene_die UntrustedSubject 'target-pull requires a selected-package reader distinct from the publisher'
  else
    [[ -z ${DIENE_ARTIFACT_ATTESTATION_DIGEST:-} && -z ${DIENE_ARTIFACT_PROVENANCE_REF:-} ]] ||
      diene_die InputContractInvalid 'non-pull lane forbids pull selectors'
  fi

  if [[ $lane == absol ]]; then
    diene_require_digest closure_digest "${DIENE_CLOSURE_DIGEST:-}"
    diene_require_digest closure_signature_bundle_digest "${DIENE_CLOSURE_SIGNATURE_BUNDLE_DIGEST:-}"
    diene_require_digest closure_trust_root_digest "${DIENE_CLOSURE_TRUST_ROOT_DIGEST:-}"
    [[ ${DIENE_CLOSURE_BUNDLE_REF:-} =~ ^[A-Za-z][A-Za-z0-9+.-]*://[^[:space:]]+$ &&
      $DIENE_CLOSURE_BUNDLE_REF == *"$GITHUB_SHA"* ]] ||
      diene_die UntrustedSubject 'closure bundle does not bind source_sha'
    [[ $DIENE_CLOSURE_DIGEST == "$DIENE_SUBJECT_CLOSURE_DIGEST" &&
      $DIENE_CLOSURE_BUNDLE_REF == "$DIENE_SUBJECT_CLOSURE_BUNDLE_REF" &&
      $DIENE_CLOSURE_SIGNATURE_BUNDLE_DIGEST == "$DIENE_SUBJECT_CLOSURE_SIGNATURE_DIGEST" &&
      $DIENE_CLOSURE_TRUST_ROOT_DIGEST == "$DIENE_SUBJECT_CLOSURE_TRUST_ROOT_DIGEST" ]] ||
      diene_die UntrustedSubject 'Absol closure inputs do not match the immutable artifact subject'
  else
    [[ -z ${DIENE_CLOSURE_DIGEST:-} && -z ${DIENE_CLOSURE_BUNDLE_REF:-} &&
      -z ${DIENE_CLOSURE_SIGNATURE_BUNDLE_DIGEST:-} && -z ${DIENE_CLOSURE_TRUST_ROOT_DIGEST:-} ]] ||
      diene_die InputContractInvalid 'non-Absol lane forbids closure selectors'
  fi

  if [[ $lane == fleet-independence ]]; then
    [[ ${DIENE_FIXTURE_ID:-} == bootstrap-fleet-independence-v1 ]] ||
      diene_die InputContractInvalid 'independence fixture ID mismatch'
  elif [[ $lane != ditto-vendor ]]; then
    [[ -z ${DIENE_FIXTURE_ID:-} ]] ||
      diene_die InputContractInvalid 'only the independence lane carries a fixture selector'
  fi
}

diene_load_subject() {
  local subject=${DIENE_ARTIFACT_SUBJECT:-}
  [[ -n $subject && -f $subject ]] ||
    diene_die ArtifactProducerUnavailable 'the same-run artifact subject handoff is absent'
  diene_schema_validate diene-artifact-subject-v1.schema.json "$subject" 'artifact subject'
  jq -e \
    --arg sha "$GITHUB_SHA" --arg runId "$GITHUB_RUN_ID" --arg runAttempt "$GITHUB_RUN_ATTEMPT" \
    --arg workflowRef "$DIENE_BASE_WORKFLOW_REF" --arg digest "$DIENE_ARTIFACT_DIGEST" '
      .sourceSha == $sha and .artifact.digest == $digest and
      .artifact.producer.runId == $runId and .artifact.producer.runAttempt == $runAttempt and
      .artifact.producer.workflowRef == $workflowRef
    ' "$subject" >/dev/null ||
    diene_die UntrustedSubject 'artifact subject is not bound to this workflow, run, attempt, source, and digest'

  DIENE_SUBJECT_IMAGE_REF=$(jq -r '.artifact.imageRef' "$subject")
  DIENE_SUBJECT_PRODUCER_WORKFLOW_REF=$(jq -r '.artifact.producer.workflowRef' "$subject")
  DIENE_SUBJECT_PROVENANCE_REF=$(jq -r '.provenance.provenanceRef // ""' "$subject")
  DIENE_SUBJECT_ATTESTATION_DIGEST=$(jq -r '.provenance.attestationDigest // ""' "$subject")
  DIENE_SUBJECT_PULL_IDENTITY=$(jq -r '.provenance.pullIdentity // ""' "$subject")
  DIENE_SUBJECT_CLOSURE_DIGEST=$(jq -r '.closure.digest // ""' "$subject")
  DIENE_SUBJECT_CLOSURE_BUNDLE_REF=$(jq -r '.closure.bundleRef // ""' "$subject")
  DIENE_SUBJECT_CLOSURE_SIGNATURE_DIGEST=$(jq -r '.closure.signatureBundleDigest // ""' "$subject")
  DIENE_SUBJECT_CLOSURE_TRUST_ROOT_DIGEST=$(jq -r '.closure.trustRootDigest // ""' "$subject")
  export DIENE_SUBJECT_IMAGE_REF DIENE_SUBJECT_PRODUCER_WORKFLOW_REF \
    DIENE_SUBJECT_PROVENANCE_REF DIENE_SUBJECT_ATTESTATION_DIGEST DIENE_SUBJECT_PULL_IDENTITY \
    DIENE_SUBJECT_CLOSURE_DIGEST DIENE_SUBJECT_CLOSURE_BUNDLE_REF \
    DIENE_SUBJECT_CLOSURE_SIGNATURE_DIGEST DIENE_SUBJECT_CLOSURE_TRUST_ROOT_DIGEST
  [[ $DIENE_SUBJECT_IMAGE_REF =~ @sha256:[0-9a-f]{64}$ && ${DIENE_SUBJECT_IMAGE_REF##*@} == "$DIENE_ARTIFACT_DIGEST" ]] ||
    diene_die UntrustedSubject 'artifact image ref is not the declared immutable digest'
}

diene_validate_report_namespace() {
  local lane=${1:?lane required}
  local core=${2:-}
  local vendor=${3:-}
  case $lane in
    ditto-vendor)
      [[ -z $core && $vendor =~ ^sha256:[0-9a-f]{64}$ ]] ||
        diene_die ReportNamespaceViolation 'vendor lane must emit vendor_report_digest only'
      ;;
    *)
      [[ -z $vendor && $core =~ ^sha256:[0-9a-f]{64}$ ]] ||
        diene_die ReportNamespaceViolation 'core lane must emit core_report_digest only'
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Stable nsc v0.0.532 lifecycle surface.
# ---------------------------------------------------------------------------

diene_nsc_bin() {
  local bin=${DIENE_NSC_BIN:-}
  [[ $bin == /* && -f $bin && ! -L $bin && -x $bin ]] ||
    diene_die NamespaceLifecycleUnavailable \
      'the declared CI shell did not select an absolute pinned nsc executable'
  printf '%s\n' "$bin"
}

diene_nsc_identity_record() {
  local bin identity_file identity binary_digest
  bin=$(diene_nsc_bin)
  identity_file=${DIENE_NSC_IDENTITY_FILE:-}
  [[ $identity_file == /* && -f $identity_file && ! -L $identity_file ]] ||
    diene_die NamespaceLifecycleUnavailable \
      'the declared CI shell did not provide the pinned nsc identity record'
  identity=$(jq -ceS \
    --arg expected "$DIENE_NSC_EXPECTED_VERSION" '
      select(
        .version == $expected and
        (.artifactDigest | test("^sha256:[0-9a-f]{64}$")) and
        (.binaryDigest | test("^sha256:[0-9a-f]{64}$")) and
        keys == ["artifactDigest","binaryDigest","version"]
      )
    ' "$identity_file") ||
    diene_die NamespaceLifecycleUnavailable 'pinned nsc identity record is malformed or has the wrong release'
  binary_digest=$(diene_file_digest "$bin")
  jq -e --arg digest "$binary_digest" '.binaryDigest == $digest' <<<"$identity" >/dev/null ||
    diene_die NamespaceLifecycleUnavailable 'nsc executable digest disagrees with its immutable identity record'
  printf '%s\n' "$identity"
}

diene_nsc_identity() {
  local bin identity output version version_count
  bin=$(diene_nsc_bin)
  identity=$(diene_nsc_identity_record)
  if ! output=$("$bin" version 2>&1); then
    diene_die NamespaceLifecycleUnavailable 'pinned nsc version probe failed'
  fi
  version=$(awk '$1 == "version" {print $2}' <<<"$output")
  version_count=$(awk '$1 == "version" {count++} END {print count+0}' <<<"$output")
  [[ $version_count == 1 && $version == "$DIENE_NSC_EXPECTED_VERSION" ]] ||
    diene_die NamespaceLifecycleUnavailable \
      "nsc must be exactly $DIENE_NSC_EXPECTED_VERSION; refusing an unmeasured client"
  jq -e --arg version "$version" '.version == $version' <<<"$identity" >/dev/null ||
    diene_die NamespaceLifecycleUnavailable 'nsc version disagrees with its immutable identity record'
  printf '%s\n' "$identity"
}

diene_nsc_version() {
  diene_nsc_identity | jq -r '.version'
}

diene_nsc_extract_cluster_id() {
  local cidfile=${1:?cidfile required}
  local metadata=${2:?metadata required}
  [[ -s $cidfile && -s $metadata ]] ||
    diene_die NamespaceIdentityMismatch 'nsc create emitted no cidfile or JSON metadata'
  local cid json_cid
  IFS= read -r cid <"$cidfile"
  json_cid=$(jq -er '.cluster_id | select(type == "string" and length > 0)' "$metadata") ||
    diene_die NamespaceIdentityMismatch 'nsc create JSON carries no exact cluster_id'
  diene_require_safe_id cluster_id "$cid"
  [[ $cid == "$json_cid" ]] ||
    diene_die NamespaceIdentityMismatch 'cidfile and JSON cluster_id disagree'
  printf '%s\n' "$cid"
}

diene_nsc_absent() {
  local cluster_id=${1:?cluster id required}
  diene_require_safe_id cluster_id "$cluster_id"
  local bin listing
  bin=$(diene_nsc_bin)
  listing=$($bin list --all -o json) || return 1
  jq -e --arg id "$cluster_id" '((. // []) | map(select(.cluster_id == $id)) | length) == 0' <<<"$listing" >/dev/null
}

diene_nsc_wait_absent() {
  local cluster_id=${1:?cluster id required}
  local bound=${DIENE_NSC_ABSENCE_WAIT_SECONDS:-30}
  local interval=${DIENE_NSC_ABSENCE_INTERVAL_SECONDS:-2}
  local waited=0
  while ((waited <= bound)); do
    if diene_nsc_absent "$cluster_id"; then
      return 0
    fi
    ((waited == bound)) && break
    sleep "$interval"
    waited=$((waited + interval))
    ((waited > bound)) && waited=$bound
  done
  return 1
}

# ---------------------------------------------------------------------------
# Exact Namespace/Garden receipt.
# ---------------------------------------------------------------------------

diene_receipt_dir() {
  local dir=${DIENE_RECEIPT_DIR:-${RUNNER_TEMP:?}/diene-receipts}
  install -d -m 0700 "$dir"
  printf '%s\n' "$dir"
}

diene_receipt_path() {
  printf '%s/%s.json\n' "$(diene_receipt_dir)" "${1:?receipt id required}"
}

diene_arm_receipt() {
  local receipt_id=${1:?receipt id required}
  local cluster_id=${2:?cluster id required}
  local create_digest=${3:?create digest required}
  local create_seconds=${4:?create seconds required}
  local cache_attached=${5:-false}
  local nsc_version=${6:?nsc version required}
  local nsc_artifact_digest=${7:?nsc artifact digest required}
  local nsc_binary_digest=${8:?nsc binary digest required}
  diene_require_safe_id receipt_id "$receipt_id"
  diene_require_safe_id cluster_id "$cluster_id"
  diene_require_digest create_receipt_digest "$create_digest"
  [[ $nsc_version == "$DIENE_NSC_EXPECTED_VERSION" ]] ||
    diene_die NamespaceLifecycleUnavailable 'receipt cannot bind an unmeasured nsc release'
  diene_require_digest nsc_artifact_digest "$nsc_artifact_digest"
  diene_require_digest nsc_binary_digest "$nsc_binary_digest"
  [[ $create_seconds =~ ^[0-9]+$ && $cache_attached =~ ^(true|false)$ ]] ||
    diene_die InputContractInvalid 'receipt create timing or cache fact is invalid'

  local lane profile build_mode egress receipt
  lane=${DIENE_LANE:?}
  profile=$(diene_runtime_profile "$lane")
  build_mode=$(diene_build_mode "$lane")
  egress=$(diene_egress_profile "$lane")
  if [[ $lane == absol || $lane == fleet-independence ]]; then
    [[ $cache_attached == false ]] || diene_die InputContractInvalid "$lane cannot bind a cache-attached receipt"
  fi
  receipt=$(diene_receipt_path "$receipt_id")
  jq -n \
    --arg repositoryId "$GITHUB_REPOSITORY_ID" --arg repositoryKey "$GITHUB_REPOSITORY" \
    --arg sourceSha "$GITHUB_SHA" --arg runId "$GITHUB_RUN_ID" --arg runAttempt "$GITHUB_RUN_ATTEMPT" \
    --arg receiptId "$receipt_id" --arg allocationKey "$(diene_allocation_key)" \
    --arg generationKey "$(diene_generation_key)" --arg workflowRef "$DIENE_BASE_WORKFLOW_REF" \
    --arg lane "$lane" --arg profile "$profile" --arg buildMode "$build_mode" \
    --arg actionId "${DIENE_ACTION_ID:-}" --arg clusterId "$cluster_id" --arg egressProfile "$egress" \
    --arg nscVersion "$nsc_version" --arg nscArtifactDigest "$nsc_artifact_digest" \
    --arg nscBinaryDigest "$nsc_binary_digest" \
    --arg createDigest "$create_digest" --arg observedAt "$(diene_timestamp)" \
    --argjson createSeconds "$create_seconds" --argjson cacheAttached "$cache_attached" '
      {
        apiVersion:"diene.atomi.cloud/ci-receipt/v1",
        owner:{repositoryId:$repositoryId,repositoryKey:$repositoryKey,sourceSha:$sourceSha,
          runId:$runId,runAttempt:$runAttempt,receiptId:$receiptId,
          allocationKey:$allocationKey,generationKey:$generationKey,workflowRef:$workflowRef},
        lane:$lane,profile:$profile,buildMode:$buildMode,
        tooling:{nscVersion:$nscVersion,nscArtifactDigest:$nscArtifactDigest,
          nscBinaryDigest:$nscBinaryDigest},
        namespace:{clusterId:$clusterId,duration:"2h",ephemeral:true,egressProfile:$egressProfile,
          cacheAttached:$cacheAttached,
          policy:{mechanism:"interim-in-guest-iptables-nft",trustBoundary:"trusted-generated-content",
            platformPerInstancePolicy:"pending-support-ask-4",applied:false,hostileProbes:"Pending"},
          create:{outcome:"Pass",reasonCode:"ExactClusterIdBound",observedAt:$observedAt,
            durationSeconds:$createSeconds,receiptDigest:$createDigest},
          destroy:{outcome:"Pending",reasonCode:"DestroyNotAttempted"},
          absence:{outcome:"Pending",reasonCode:"AbsenceNotAttempted"}},
        runtimeFile:null,
        cleanup:{outcome:"Pending",reasonCode:"RuntimeArmed",debt:[]}
      }
      + (if $actionId == "" then {} else {actionId:$actionId} end)
    ' | diene_write_json "$receipt"
  diene_schema_validate diene-ci-receipt-v1.schema.json "$receipt" 'armed Namespace receipt'
  printf '%s\n' "$receipt"
}

diene_receipt_patch() {
  local receipt=${1:?receipt required}
  local filter=${2:?filter required}
  shift 2
  local rendered
  rendered=$(jq "$@" "$filter" "$receipt") || diene_die CleanupDebt 'receipt patch failed'
  printf '%s\n' "$rendered" | diene_write_json "$receipt"
}

diene_validate_receipt_owner() {
  local receipt=${1:?receipt required}
  local cluster_id=${2:-}
  local lane=${DIENE_LANE:?lane required} profile build_mode egress_profile
  profile=$(diene_runtime_profile "$lane")
  build_mode=$(diene_build_mode "$lane")
  egress_profile=$(diene_egress_profile "$lane")
  diene_schema_validate diene-ci-receipt-v1.schema.json "$receipt" 'exact receipt'
  jq -e \
    --arg repositoryId "$GITHUB_REPOSITORY_ID" --arg repositoryKey "$GITHUB_REPOSITORY" \
    --arg sourceSha "$GITHUB_SHA" --arg runId "$GITHUB_RUN_ID" --arg runAttempt "$GITHUB_RUN_ATTEMPT" \
    --arg receiptId "$(diene_receipt_id)" --arg workflowRef "$DIENE_BASE_WORKFLOW_REF" \
    --arg allocationKey "$(diene_allocation_key)" --arg generationKey "$(diene_generation_key)" \
    --arg clusterId "$cluster_id" --arg nscVersion "${DIENE_NSC_VERSION:-}" \
    --arg nscArtifactDigest "${DIENE_NSC_ARTIFACT_DIGEST:-}" \
    --arg nscBinaryDigest "${DIENE_NSC_BINARY_DIGEST:-}" --arg lane "$lane" \
    --arg profile "$profile" --arg buildMode "$build_mode" --arg egressProfile "$egress_profile" \
    --arg actionId "${DIENE_ACTION_ID:-}" '
      .owner.repositoryId == $repositoryId and .owner.repositoryKey == $repositoryKey and
      .owner.sourceSha == $sourceSha and .owner.runId == $runId and
      .owner.runAttempt == $runAttempt and .owner.receiptId == $receiptId and
      .owner.allocationKey == $allocationKey and .owner.generationKey == $generationKey and
      .owner.workflowRef == $workflowRef and
      .lane == $lane and .profile == $profile and .buildMode == $buildMode and
      .namespace.egressProfile == $egressProfile and
      (if $lane == "ditto-vendor" then .actionId == $actionId else has("actionId") | not end) and
      ($clusterId == "" or .namespace.clusterId == $clusterId) and
      ($nscVersion == "" or (.tooling.nscVersion == $nscVersion and
        .tooling.nscArtifactDigest == $nscArtifactDigest and
        .tooling.nscBinaryDigest == $nscBinaryDigest))
    ' "$receipt" >/dev/null || diene_die ReceiptOwnershipMismatch 'receipt owner tuple or exact cluster_id mismatch'
}

diene_validate_terminal_receipt() {
  local receipt=${1:?receipt required}
  local lifecycle=${2:?lifecycle required}
  local checkpoint=${3:?checkpoint required}
  local report=${4:?terminal report required}
  [[ -f $receipt && ! -L $receipt && -f $lifecycle && ! -L $lifecycle &&
    -f $checkpoint && ! -L $checkpoint &&
    -f $report && ! -L $report ]] ||
    diene_die ReceiptLifecycleIncomplete \
      'terminal receipt bindings require regular receipt, lifecycle, checkpoint, and report files'

  local cluster_id lifecycle_digest checkpoint_digest report_digest
  cluster_id=$(jq -er '.clusterId | select(type == "string" and length > 0)' "$lifecycle") ||
    diene_die ReceiptLifecycleIncomplete 'terminal lifecycle carries no exact cluster_id'
  if ! (DIENE_REASON_FILE='' diene_validate_receipt_owner "$receipt" "$cluster_id" >/dev/null 2>&1); then
    diene_die ReceiptLifecycleIncomplete \
      'terminal receipt owner, lane, tool identity, or exact cluster binding is invalid'
  fi
  lifecycle_digest=$(diene_file_digest "$lifecycle")
  checkpoint_digest=$(diene_file_digest "$checkpoint")
  report_digest=$(diene_file_digest "$report")

  jq -e --slurpfile lifecycle "$lifecycle" --slurpfile checkpoint "$checkpoint" '
    .namespaceLifecycle == $lifecycle[0] and .checkpointChain == $checkpoint[0]
  ' "$report" >/dev/null ||
    diene_die ReceiptLifecycleIncomplete \
      'terminal report does not embed the exact standalone lifecycle and checkpoint objects'

  jq -e --slurpfile lifecycle "$lifecycle" --slurpfile report "$report" \
    --arg lane "$DIENE_LANE" --arg profile "$(diene_runtime_profile "$DIENE_LANE")" \
    --arg buildMode "$(diene_build_mode "$DIENE_LANE")" \
    --arg lifecycleDigest "$lifecycle_digest" --arg checkpointDigest "$checkpoint_digest" \
    --arg reportDigest "$report_digest" '
      .lane == $lane and .profile == $profile and .buildMode == $buildMode and
      .namespace.clusterId == $lifecycle[0].clusterId and
      .namespace.duration == $lifecycle[0].duration and
      .namespace.ephemeral == $lifecycle[0].ephemeral and
      .namespace.cacheAttached == $lifecycle[0].cacheAttached and
      .namespace.policy.applied == true and .namespace.policy.hostileProbes == "Pass" and
      .namespace.policy.platformPerInstancePolicy == "pending-support-ask-4" and
      .namespace.create.outcome == "Pass" and .namespace.destroy.outcome == "Pass" and
      .namespace.absence.outcome == "Pass" and
      ((.namespace.create | del(.observedAt)) == $lifecycle[0].create) and
      .namespace.destroy == $lifecycle[0].destroy and
      .namespace.absence == $lifecycle[0].absence and
      .cleanup.outcome == "Pass" and
      (.cleanup.debt | type == "array" and length == 0) and
      .checkpointChainDigest == $checkpointDigest and
      .lifecycleDigest == $lifecycleDigest and
      .terminalReportDigest == $reportDigest and
      .tooling.nscVersion == $report[0].tooling.nscVersion and
      .tooling.nscArtifactDigest == $report[0].tooling.nscArtifactDigest and
      .tooling.nscBinaryDigest == $report[0].tooling.nscBinaryDigest
    ' "$receipt" >/dev/null ||
    diene_die ReceiptLifecycleIncomplete \
      'terminal receipt phases, cleanup, policy, identity, or digests are incomplete or unbound'
}

diene_discover_runtime() {
  local profile=${1:?profile required}
  local allocation_key=${2:?allocation key required}
  local generation_key=${3:?generation key required}
  local search_root=${DIENE_RUNTIME_SEARCH_ROOT:-${RUNNER_TEMP:?}}
  local -a matches=()
  local candidate
  while IFS= read -r -d '' candidate; do
    jq -e \
      --arg repositoryId "$GITHUB_REPOSITORY_ID" --arg repositoryKey "$GITHUB_REPOSITORY" \
      --arg allocationKey "$allocation_key" --arg generationKey "$generation_key" \
      --arg profile "$profile" '
        .apiVersion == "diene-runtime/v1" and .profile == $profile and
        (.owner.repositoryId | tostring) == $repositoryId and .owner.repositoryKey == $repositoryKey and
        .owner.allocationKey == $allocationKey and .owner.generationKey == $generationKey and
        .substrate.kind == "k3d"
      ' "$candidate" >/dev/null 2>&1 && matches+=("$candidate")
  done < <(find "$search_root" -type f -name '*.json' -print0 2>/dev/null)
  ((${#matches[@]} == 1)) ||
    diene_die RuntimeEvidenceUnavailable "expected one exact Garden runtime record, found ${#matches[@]}"
  local runtime=${matches[0]}
  [[ $(stat -c %a "$runtime") == 600 ]] ||
    diene_die RuntimeEvidenceUnavailable 'Garden runtime file is not mode 0600'
  diene_schema_validate diene-runtime-consumption-v1.schema.json "$runtime" 'Garden runtime record'
  printf '%s\n' "$runtime"
}

# ---------------------------------------------------------------------------
# Immutable checkpoint predecessor chain.
# ---------------------------------------------------------------------------

diene_checkpoint_init() {
  local file=${1:?checkpoint file required}
  local input_digest=${2:?input digest required}
  diene_require_digest input_digest "$input_digest"
  jq -n --arg input "$input_digest" '
    {apiVersion:"diene.atomi.cloud/ci-checkpoint-chain/v1",inputDigest:$input,
      checkpoints:[],validated:false,resumedLegs:0,finalCleanPass:false}' |
    diene_write_json "$file"
}

diene_checkpoint_append() {
  local file=${1:?checkpoint file required}
  local id=${2:?checkpoint id required}
  local outcome=${3:?outcome required}
  local evidence_digest=${4:?evidence digest required}
  local resumed=${5:-false}
  [[ $id =~ ^[a-z][a-z0-9-]{0,63}$ && $outcome =~ ^(Pass|Fail)$ && $resumed =~ ^(true|false)$ ]] ||
    diene_die CheckpointChainInvalid 'checkpoint id, outcome, or resumed marker is invalid'
  diene_require_digest checkpoint_evidence_digest "$evidence_digest"
  [[ -f $file ]] || diene_die CheckpointChainInvalid 'checkpoint chain is absent'
  local input predecessor base digest entry rendered
  input=$(jq -er '.inputDigest' "$file")
  predecessor=$(jq -r --arg zero "$DIENE_ZERO_DIGEST" '.checkpoints[-1].receiptDigest // $zero' "$file")
  base=$(jq -cn --arg id "$id" --arg input "$input" --arg predecessor "$predecessor" \
    --arg evidence "$evidence_digest" --arg outcome "$outcome" --argjson resumed "$resumed" \
    '{id:$id,inputDigest:$input,predecessorDigest:$predecessor,evidenceDigest:$evidence,
      outcome:$outcome,resumed:$resumed}')
  digest=$(diene_sha256_text "$(jq -cS . <<<"$base")")
  entry=$(jq -c --arg digest "$digest" '. + {receiptDigest:$digest}' <<<"$base")
  rendered=$(jq --argjson entry "$entry" '.checkpoints += [$entry] | .validated = false | .finalCleanPass = false' "$file")
  printf '%s\n' "$rendered" | diene_write_json "$file"
}

diene_checkpoint_validate() {
  local file=${1:?checkpoint file required}
  [[ -f $file ]] || diene_die CheckpointChainInvalid 'checkpoint chain is absent'
  local input count index predecessor checkpoint actual declared resumed_count
  input=$(jq -er '.inputDigest' "$file")
  diene_require_digest input_digest "$input"
  count=$(jq -r '.checkpoints | length' "$file")
  ((count > 0)) || diene_die CheckpointChainInvalid 'checkpoint chain is empty'
  predecessor=$DIENE_ZERO_DIGEST
  resumed_count=0
  for ((index = 0; index < count; index++)); do
    checkpoint=$(jq -c ".checkpoints[$index]" "$file")
    [[ $(jq -r '.inputDigest' <<<"$checkpoint") == "$input" ]] ||
      diene_die CheckpointChainInvalid "checkpoint $index input digest changed"
    [[ $(jq -r '.predecessorDigest' <<<"$checkpoint") == "$predecessor" ]] ||
      diene_die CheckpointChainInvalid "checkpoint $index predecessor mismatch"
    declared=$(jq -r '.receiptDigest' <<<"$checkpoint")
    actual=$(diene_sha256_text "$(jq -cS 'del(.receiptDigest)' <<<"$checkpoint")")
    [[ $declared == "$actual" ]] || diene_die CheckpointChainInvalid "checkpoint $index receipt digest mismatch"
    [[ $(jq -r '.resumed' <<<"$checkpoint") != true ]] || resumed_count=$((resumed_count + 1))
    predecessor=$declared
  done
  DIENE_CHECKPOINT_RESUMED_COUNT=$resumed_count
  export DIENE_CHECKPOINT_RESUMED_COUNT
}

diene_checkpoint_seal() {
  local file=${1:?checkpoint file required}
  local require_final=${2:-false}
  diene_checkpoint_validate "$file"
  local final_clean=false all_pass=false
  if jq -e 'all(.checkpoints[]; .outcome == "Pass")' "$file" >/dev/null; then
    all_pass=true
  fi
  if [[ $(jq -r '.checkpoints[-1].id' "$file") == final-clean-pass &&
    $(jq -r '.checkpoints[-1].outcome' "$file") == Pass &&
    $DIENE_CHECKPOINT_RESUMED_COUNT == 0 && $all_pass == true ]]; then
    final_clean=true
  fi
  [[ $require_final != true || $final_clean == true ]] ||
    diene_die FinalCleanPassRequired 'release evidence requires a final clean full pass with no resumed leg'
  jq --argjson resumed "$DIENE_CHECKPOINT_RESUMED_COUNT" --argjson final "$final_clean" \
    '.validated = true | .resumedLegs = $resumed | .finalCleanPass = $final' "$file" |
    diene_write_json "$file"
}

# ---------------------------------------------------------------------------
# Remote input boundary. The copied driver receives immutable files only and
# refuses every orchestrator credential/capability crossover.
# ---------------------------------------------------------------------------

diene_refuse_driver_authority_crossover() {
  local name
  for name in NSC_TOKEN NAMESPACE_TOKEN GITHUB_TOKEN GH_TOKEN ACTIONS_ID_TOKEN_REQUEST_TOKEN \
    ACTIONS_ID_TOKEN_REQUEST_URL SSH_AUTH_SOCK DIENE_NSC_KEYCHAIN DIENE_NSC_DESTROY_AUTHORITY \
    DIENE_VENDOR_CREDENTIAL; do
    [[ -z ${!name:-} ]] ||
      diene_die CredentialBoundaryViolation "$name crossed into the on-instance driver"
  done
  # The shared pinned shell may expose the nsc executable on both sides of the
  # SSH boundary. Presence of a client binary is not authority. Credentials,
  # keychains, an agent socket, and the explicit destroy capability above are
  # the boundary; the driver never invokes nsc.
  return 0
}

# ---------------------------------------------------------------------------
# Admitted built-in Kubernetes substrate. This is the single source of truth
# for the admitted full k3s version and for the exactly one Namespace create
# feature derived from it, so the create selector and the version admitted to
# the guest can no longer drift apart. Malformed or unsupported admission
# fails before create.
# ---------------------------------------------------------------------------
DIENE_DEFAULT_ADMITTED_K3S_VERSION=v1.33.1+k3s1
# Pinned nsc v0.0.532 `create --help` exposes exactly this Kubernetes feature
# selector. A derived feature outside this set is unsupported admission, never
# a silent platform-default create.
DIENE_SUPPORTED_KUBERNETES_FEATURE=kubernetes:1.33

# Concrete-value validators. A dotted-quad shape is not enough: every octet,
# prefix length, and port must be a real in-range value, so a malformed
# observation can never be carried into a policy rule or an admission compare.
diene_ipv4_valid() {
  local address=${1-} octet
  [[ $address =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  local -a octets=()
  IFS=. read -r -a octets <<<"$address"
  ((${#octets[@]} == 4)) || return 1
  for octet in "${octets[@]}"; do
    [[ $octet == 0 || $octet =~ ^[1-9][0-9]{0,2}$ ]] || return 1
    ((octet <= 255)) || return 1
  done
  return 0
}

diene_ipv4_cidr_valid() {
  local cidr=${1-} address prefix
  [[ $cidr =~ ^(([0-9]{1,3}\.){3}[0-9]{1,3})/([0-9]{1,2})$ ]] || return 1
  address=${BASH_REMATCH[1]}
  prefix=${BASH_REMATCH[3]}
  [[ $prefix == 0 || $prefix =~ ^[1-9][0-9]?$ ]] || return 1
  ((prefix <= 32)) || return 1
  diene_ipv4_valid "$address"
}

diene_tcp_port_valid() {
  [[ ${1-} =~ ^[1-9][0-9]{0,4}$ ]] || return 1
  (($1 <= 65535))
}

# Prints "<admitted-full-version> <derived-namespace-feature>". An explicitly
# supplied empty admission refuses, and so does a set-but-empty environment
# admission; only a completely omitted argument with a completely unset
# environment variable may fall back to the default.
diene_k3s_admission() {
  local admitted
  if (($# >= 1)); then
    admitted=$1
  elif [[ -n ${DIENE_ADMITTED_K3S_VERSION+set} ]]; then
    admitted=$DIENE_ADMITTED_K3S_VERSION
  else
    admitted=$DIENE_DEFAULT_ADMITTED_K3S_VERSION
  fi
  local number='(0|[1-9][0-9]*)'
  local exact_version="^v$number\\.$number\\.$number\\+k3s$number\$"
  [[ $admitted =~ $exact_version ]] ||
    diene_die InputContractInvalid \
      "admitted built-in k3s version ${admitted:-missing} is not the exact vMAJOR.MINOR.PATCH+k3sREV form"
  local feature=kubernetes:${BASH_REMATCH[1]}.${BASH_REMATCH[2]}
  [[ $feature == "$DIENE_SUPPORTED_KUBERNETES_FEATURE" ]] ||
    diene_die InputContractInvalid \
      "admitted built-in k3s version $admitted derives unsupported Namespace feature $feature"
  printf '%s %s\n' "$admitted" "$feature"
}

# Both independently observed runtime versions must equal the same admitted
# full version. The k3s binary alone is not authority for the served
# Kubernetes control plane, so neither observation may be skipped.
diene_require_admitted_k3s_runtime() {
  local admitted=${1-} observed_k3s=${2-} observed_kubernetes=${3-} admission
  [[ -n $admitted ]] ||
    diene_die InstancePostureUnavailable 'the admitted built-in k3s version is absent'
  admission=$(diene_k3s_admission "$admitted")
  admitted=${admission%% *}
  [[ -n $observed_k3s && $observed_k3s == "$admitted" ]] ||
    diene_die InstancePostureUnavailable \
      "built-in k3s ${observed_k3s:-missing} does not match admitted $admitted"
  [[ -n $observed_kubernetes && $observed_kubernetes == "$admitted" ]] ||
    diene_die InstancePostureUnavailable \
      "Kubernetes server ${observed_kubernetes:-missing} does not match admitted $admitted"
}

# The admitted service range must be read from the one API object that the
# apiserver itself derives from --service-cluster-ip-range. A single ClusterIP,
# a route, or a k3s argv/config guess cannot establish a range, so an
# unobservable object is a precise red rather than an inferred value.
diene_observe_admitted_service_cidr() {
  local admitted=${1-}
  [[ -n $admitted ]] ||
    diene_die InstancePostureUnavailable 'the admitted built-in k3s service CIDR is absent'
  diene_ipv4_cidr_valid "$admitted" ||
    diene_die InputContractInvalid 'the admitted built-in k3s service CIDR is invalid'
  local kubectl_bin=${DIENE_KUBECTL_BIN:-kubectl} observed cidr
  observed=$("$kubectl_bin" get servicecidrs.networking.k8s.io kubernetes -o json) ||
    diene_die ServiceCidrObservationUnavailable \
      'the default networking.k8s.io/v1 ServiceCIDR object kubernetes is not observable'
  jq -e '
    .apiVersion == "networking.k8s.io/v1" and .kind == "ServiceCIDR" and
    .metadata.name == "kubernetes" and
    (.spec.cidrs | type == "array" and length == 1) and
    (.spec.cidrs[0] | type == "string")
  ' <<<"$observed" >/dev/null ||
    diene_die ServiceCidrObservationUnavailable \
      'the ServiceCIDR object is not one exact networking.k8s.io/v1 kubernetes range'
  cidr=$(jq -r '.spec.cidrs[0]' <<<"$observed")
  diene_ipv4_cidr_valid "$cidr" ||
    diene_die ServiceCidrObservationUnavailable \
      "the observed ServiceCIDR range $cidr is not a concrete IPv4 range"
  [[ $cidr == "$admitted" ]] ||
    diene_die InstancePostureUnavailable \
      "observed service CIDR $cidr does not match admitted $admitted"
  printf '%s\n' "$cidr"
}

diene_load_remote_inputs() {
  local state_dir=${1:?state directory required}
  [[ $state_dir == /run/diene-ci && ! -L $state_dir ]] ||
    diene_die InputContractInvalid 'driver state directory must be the fixed /run/diene-ci path'
  local input="$state_dir/inputs.json" guest_nix_contract guest_toolchain_contract
  [[ -f $input && ! -L $input ]] || diene_die InputContractInvalid 'immutable driver inputs are absent'
  jq -e '
    .apiVersion == "diene.atomi.cloud/ci-driver-inputs/v1" and
    .trustedRuntimeContext == "protected-base" and .duration == "2h" and
    .platformPolicyStatus == "platform per-instance policy pending (support ask #4)" and
    (.clusterId | type == "string" and length > 0) and
    .nscVersion == "v0.0.532" and
    (.nscArtifactDigest | test("^sha256:[0-9a-f]{64}$")) and
    (.nscBinaryDigest | test("^sha256:[0-9a-f]{64}$")) and
    (.archiveValidatorDigest | test("^sha256:[0-9a-f]{64}$")) and
    (.sourceArchiveDigest | test("^sha256:[0-9a-f]{64}$")) and
    (.artifactSubjectDigest | test("^sha256:[0-9a-f]{64}$")) and
    (.admittedK3sVersion | test("^v[0-9]+\\.[0-9]+\\.[0-9]+\\+k3s[0-9]+$")) and
    (.admittedServiceCidr | test("^([0-9]{1,3}\\.){3}[0-9]{1,3}/[0-9]{1,2}$")) and
    (.egress.contractDigest | test("^sha256:[0-9a-f]{64}$")) and
    (.egress.canaryImage | test("@sha256:[0-9a-f]{64}$")) and
    (.guestNix | type == "object") and
    (.guestToolchain | type == "object")
  ' "$input" >/dev/null || diene_die InputContractInvalid 'immutable driver input shape is invalid'
  guest_nix_contract=$(diene_guest_nix_contract) || exit $?
  jq -e --argjson contract "$guest_nix_contract" '.guestNix == $contract' "$input" >/dev/null ||
    diene_die InputContractInvalid 'immutable guest Nix input differs from the fixed pinned contract'
  guest_toolchain_contract=$(diene_guest_toolchain_contract) || exit $?
  jq -e --argjson contract "$guest_toolchain_contract" '.guestToolchain == $contract' "$input" >/dev/null ||
    diene_die InputContractInvalid \
      'immutable guest toolchain input differs from the fixed pinned contract'

  export GITHUB_REPOSITORY_ID GITHUB_REPOSITORY GITHUB_SHA GITHUB_RUN_ID GITHUB_RUN_ATTEMPT
  export DIENE_BASE_WORKFLOW_REF DIENE_LANE DIENE_GARDEN_LOCK_DIGEST DIENE_ARTIFACT_DIGEST
  export DIENE_ARTIFACT_PROVENANCE_REF DIENE_ARTIFACT_ATTESTATION_DIGEST
  export DIENE_JOURNEY_MANIFEST DIENE_VENDOR_MANIFEST DIENE_ACTION_ID DIENE_FIXTURE_ID
  export DIENE_CLOSURE_DIGEST DIENE_CLOSURE_BUNDLE_REF
  export DIENE_CLOSURE_SIGNATURE_BUNDLE_DIGEST DIENE_CLOSURE_TRUST_ROOT_DIGEST
  export DIENE_TRUSTED_RUNTIME_CONTEXT DIENE_NSC_CLUSTER_ID DIENE_NSC_VERSION
  export DIENE_NSC_ARTIFACT_DIGEST DIENE_NSC_BINARY_DIGEST
  export DIENE_SOURCE_ARCHIVE_DIGEST DIENE_ORCHESTRATOR_VENUE DIENE_ORCHESTRATOR_LABEL
  export DIENE_ORCHESTRATOR_FALLBACK_REASON DIENE_CACHE_ATTACHED
  export DIENE_ADMITTED_K3S_VERSION DIENE_EGRESS_CANARY_IMAGE
  export DIENE_EGRESS_CONTRACT DIENE_EGRESS_L7_ENFORCER_BIN DIENE_EGRESS_PROBE_BIN
  export DIENE_K3S_SERVICE_CIDR
  export DIENE_VENDOR_CREDENTIAL_BROKER_BIN
  export DIENE_GUEST_NIX_INPUT DIENE_GUEST_NIX_INSTALLER_PATH DIENE_GUEST_NIX_PAYLOAD_PATH
  export DIENE_GUEST_TOOLCHAIN_INPUT

  GITHUB_REPOSITORY_ID=$(jq -r '.owner.repositoryId' "$input")
  GITHUB_REPOSITORY=$(jq -r '.owner.repositoryKey' "$input")
  GITHUB_SHA=$(jq -r '.owner.sourceSha' "$input")
  GITHUB_RUN_ID=$(jq -r '.owner.runId' "$input")
  GITHUB_RUN_ATTEMPT=$(jq -r '.owner.runAttempt' "$input")
  DIENE_BASE_WORKFLOW_REF=$(jq -r '.owner.workflowRef' "$input")
  DIENE_LANE=$(jq -r '.lane' "$input")
  DIENE_GARDEN_LOCK_DIGEST=$(jq -r '.gardenLockDigest' "$input")
  DIENE_ARTIFACT_DIGEST=$(jq -r '.artifact.digest' "$input")
  DIENE_ARTIFACT_PROVENANCE_REF=$(jq -r '.artifact.provenanceRef // ""' "$input")
  DIENE_ARTIFACT_ATTESTATION_DIGEST=$(jq -r '.artifact.attestationDigest // ""' "$input")
  DIENE_JOURNEY_MANIFEST=$(jq -r '.selectors.journeyManifest // ""' "$input")
  DIENE_VENDOR_MANIFEST=$(jq -r '.selectors.vendorManifest // ""' "$input")
  DIENE_ACTION_ID=$(jq -r '.selectors.actionId // ""' "$input")
  DIENE_FIXTURE_ID=$(jq -r '.selectors.fixtureId // ""' "$input")
  DIENE_CLOSURE_DIGEST=$(jq -r '.closure.digest // ""' "$input")
  DIENE_CLOSURE_BUNDLE_REF=$(jq -r '.closure.bundleRef // ""' "$input")
  DIENE_CLOSURE_SIGNATURE_BUNDLE_DIGEST=$(jq -r '.closure.signatureBundleDigest // ""' "$input")
  DIENE_CLOSURE_TRUST_ROOT_DIGEST=$(jq -r '.closure.trustRootDigest // ""' "$input")
  DIENE_TRUSTED_RUNTIME_CONTEXT=protected-base
  DIENE_NSC_CLUSTER_ID=$(jq -r '.clusterId' "$input")
  DIENE_NSC_VERSION=$(jq -r '.nscVersion' "$input")
  DIENE_NSC_ARTIFACT_DIGEST=$(jq -r '.nscArtifactDigest' "$input")
  DIENE_NSC_BINARY_DIGEST=$(jq -r '.nscBinaryDigest' "$input")
  DIENE_SOURCE_ARCHIVE_DIGEST=$(jq -r '.sourceArchiveDigest' "$input")
  DIENE_ORCHESTRATOR_VENUE=$(jq -r '.orchestrator.venue' "$input")
  DIENE_ORCHESTRATOR_LABEL=$(jq -r '.orchestrator.label' "$input")
  DIENE_ORCHESTRATOR_FALLBACK_REASON=$(jq -r '.orchestrator.fallbackReason // ""' "$input")
  DIENE_CACHE_ATTACHED=$(jq -r '.cacheAttached' "$input")
  DIENE_ADMITTED_K3S_VERSION=$(jq -r '.admittedK3sVersion' "$input")
  DIENE_K3S_SERVICE_CIDR=$(jq -r '.admittedServiceCidr' "$input")
  DIENE_EGRESS_CANARY_IMAGE=$(jq -r '.egress.canaryImage' "$input")
  DIENE_EGRESS_L7_ENFORCER_BIN=$(jq -r '.egress.l7Enforcer // ""' "$input")
  DIENE_EGRESS_PROBE_BIN=$(jq -r '.egress.probeBin // ""' "$input")
  DIENE_VENDOR_CREDENTIAL_BROKER_BIN=$(jq -r '.vendorCredentialBroker // ""' "$input")
  DIENE_EGRESS_CONTRACT="$state_dir/egress-contract.json"
  DIENE_ARTIFACT_SUBJECT="$state_dir/artifact-subject.json"
  DIENE_GUEST_NIX_INPUT=$input
  DIENE_GUEST_TOOLCHAIN_INPUT=$input
  DIENE_GUEST_NIX_INSTALLER_PATH="$state_dir/guest-nix-bootstrap.sh"
  DIENE_GUEST_NIX_PAYLOAD_PATH="$state_dir/guest-nix-installer"
  export DIENE_ARTIFACT_SUBJECT

  [[ $(diene_file_digest "$state_dir/source.tar") == "$DIENE_SOURCE_ARCHIVE_DIGEST" ]] ||
    diene_die UntrustedSubject 'copied source archive digest mismatch'
  [[ -f $state_dir/archive-validator.sh && ! -L $state_dir/archive-validator.sh &&
    $(diene_file_digest "$state_dir/archive-validator.sh") == "$(jq -r '.archiveValidatorDigest' "$input")" ]] ||
    diene_die UntrustedSubject 'copied remote archive validator digest mismatch'
  [[ $(diene_file_digest "$DIENE_ARTIFACT_SUBJECT") == "$(jq -r '.artifactSubjectDigest' "$input")" ]] ||
    diene_die UntrustedSubject 'copied artifact subject digest mismatch'
  [[ -f $DIENE_EGRESS_CONTRACT && ! -L $DIENE_EGRESS_CONTRACT ]] ||
    diene_die InputContractInvalid 'immutable egress contract is absent'
  [[ $(diene_file_digest "$DIENE_EGRESS_CONTRACT") == "$(jq -r '.egress.contractDigest' "$input")" ]] ||
    diene_die UntrustedSubject 'copied egress contract digest mismatch'
  [[ $DIENE_ADMITTED_K3S_VERSION =~ ^v[0-9]+\.[0-9]+\.[0-9]+\+k3s[0-9]+$ ]] ||
    diene_die InputContractInvalid 'admitted built-in k3s version is invalid'
  [[ $DIENE_K3S_SERVICE_CIDR =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]] ||
    diene_die InputContractInvalid 'admitted built-in k3s service CIDR is invalid'
  [[ $DIENE_EGRESS_CANARY_IMAGE =~ @sha256:[0-9a-f]{64}$ ]] ||
    diene_die InputContractInvalid 'egress canary image must be an immutable digest reference'
  diene_require_safe_id cluster_id "$DIENE_NSC_CLUSTER_ID"
  diene_refuse_driver_authority_crossover
}

# ---------------------------------------------------------------------------
# Lead-ratified interim in-guest policy. This is not represented as final
# platform enforcement. It is permitted only for trusted generated content;
# every run must apply receipt-scoped iptables rules on the measured nf_tables
# backend before workload mutation and pass hostile
# negative probes. Namespace per-instance policy remains support ask #4.
# ---------------------------------------------------------------------------

diene_policy_mode() {
  case ${1:?lane required} in
    absol | fleet-independence) printf 'hermetic\n' ;;
    ditto-build-local | ditto-target-pull | ditto-vendor) printf 'allowlist\n' ;;
    *) diene_die InputContractInvalid "unknown lane $1" ;;
  esac
}

diene_require_source_executable() {
  local label=${1:?capability label required}
  local path=${2:-}
  local reason=${3:-ConnectedEgressInterfaceUnavailable}
  [[ -n $path && $path != /* && $path != *'..'* &&
    $path =~ ^[A-Za-z0-9._/-]+$ ]] ||
    diene_die "$reason" \
      "$label must be a safe repository-relative executable copied with the pinned source"
  [[ -f $path && -x $path && ! -L $path ]] ||
    diene_die "$reason" \
      "$label $path is absent, non-executable, or a link before nsc create"
}

diene_prepare_egress_contract() {
  local target=${1:?egress contract target required}
  local profile mode entries
  profile=$(diene_egress_profile "${DIENE_LANE:?}")
  mode=$(diene_policy_mode "$DIENE_LANE")
  entries='[]'
  if [[ $mode == allowlist ]]; then
    if [[ $DIENE_LANE == ditto-vendor ]]; then
      [[ -f ${DIENE_VENDOR_MANIFEST:-} ]] ||
        diene_die InputContractInvalid 'vendor egress declaration is absent'
      entries=$(jq -cer --arg id "${DIENE_ACTION_ID:?}" \
        '[.actions[] | select(.actionId == $id) | .egress[]] | select(length > 0)' \
        "$DIENE_VENDOR_MANIFEST") ||
        diene_die ConnectedEgressInterfaceUnavailable 'vendor action has no exact egress declaration'
      [[ -n ${DIENE_VENDOR_CREDENTIAL_BROKER_BIN:-} ]] ||
        diene_die VendorBrokerInterfaceUnavailable \
          'vendor lane requires an approved phase broker; credential bytes never cross the orchestrator boundary'
      diene_require_source_executable 'vendor credential broker' \
        "$DIENE_VENDOR_CREDENTIAL_BROKER_BIN" VendorBrokerInterfaceUnavailable
    else
      [[ -n ${DIENE_CONNECTED_EGRESS_JSON:-} ]] ||
        diene_die ConnectedEgressInterfaceUnavailable \
          "$DIENE_LANE requires a protected exact DNS/SNI/port/method egress contract"
      entries=$(jq -cer 'select(type == "array" and length > 0)' <<<"$DIENE_CONNECTED_EGRESS_JSON") ||
        diene_die ConnectedEgressInterfaceUnavailable 'connected egress contract is not a non-empty JSON array'
    fi
    jq -e '
      type == "array" and length > 0 and
      all(type == "object" and
          ((keys | sort) == ["dns","methods","port","sni"]) and
          (.dns | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9.-]*$")) and
          (.sni | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9.-]*$")) and
          (.port | type == "number" and . >= 1 and . <= 65535) and
          (.methods | type == "array" and length > 0 and
            all(. == "GET" or . == "POST" or . == "DELETE"))) and
      ([.[] | [.dns,.sni,(.port|tostring),(.methods|sort|join(","))] | join("|")] |
        length == (unique | length))
    ' <<<"$entries" >/dev/null ||
      diene_die ConnectedEgressInterfaceUnavailable 'connected egress entries are invalid or duplicated'

    [[ -n ${DIENE_EGRESS_L7_ENFORCER_BIN:-} ]] ||
      diene_die ConnectedEgressInterfaceUnavailable \
        'connected profiles require an L7 enforcer for declared DNS, SNI and method boundaries'
    diene_require_source_executable 'connected L7 enforcer' "$DIENE_EGRESS_L7_ENFORCER_BIN"
    if [[ $DIENE_LANE == ditto-target-pull ]]; then
      local registry
      registry=$(jq -er '.artifact.registry' "${DIENE_ARTIFACT_SUBJECT:?}")
      jq -e --arg registry "$registry" 'any(.[]; .dns == $registry)' <<<"$entries" >/dev/null ||
        diene_die ConnectedEgressInterfaceUnavailable \
          'target-pull egress does not include the immutable subject registry'
    fi
  fi
  [[ ${DIENE_EGRESS_CANARY_IMAGE:-} =~ @sha256:[0-9a-f]{64}$ ]] ||
    diene_die InterimPolicyUnavailable \
      'a preloaded immutable host/pod egress-canary image is required before instance creation'
  if [[ -n ${DIENE_EGRESS_PROBE_BIN:-} ]]; then
    diene_require_source_executable 'hostile egress probe adapter' "$DIENE_EGRESS_PROBE_BIN"
  fi
  jq -n --arg profile "$profile" --arg mode "$mode" --argjson entries "$entries" '
    {apiVersion:"diene.atomi.cloud/ci-egress-contract/v1",profileId:$profile,
     mode:$mode,entries:$entries,
     platformStatus:"platform per-instance policy pending (support ask #4)"}' |
    diene_write_json "$target"
}

diene_resolve_egress_contract() {
  local contract=${1:?egress contract required}
  local output=${2:?resolved egress output required}
  local resolved='[]' entry dns ipv4 ipv6
  while IFS= read -r entry; do
    dns=$(jq -r '.dns' <<<"$entry")
    if [[ -n ${DIENE_EGRESS_RESOLVER_BIN:-} ]]; then
      diene_require_command "$DIENE_EGRESS_RESOLVER_BIN"
      ipv4=$("$DIENE_EGRESS_RESOLVER_BIN" ipv4 "$dns" | jq -Rsc 'split("\n") | map(select(length > 0)) | unique')
      ipv6=$("$DIENE_EGRESS_RESOLVER_BIN" ipv6 "$dns" | jq -Rsc 'split("\n") | map(select(length > 0)) | unique')
    else
      diene_require_command getent
      ipv4=$(getent ahostsv4 "$dns" 2>/dev/null | awk '{print $1}' | sort -u |
        jq -Rsc 'split("\n") | map(select(length > 0))')
      ipv6=$(getent ahostsv6 "$dns" 2>/dev/null | awk '{print $1}' | sort -u |
        jq -Rsc 'split("\n") | map(select(length > 0))')
    fi
    jq -e 'all(.[]; test("^([0-9]{1,3}\\.){3}[0-9]{1,3}$"))' <<<"$ipv4" >/dev/null ||
      diene_die ConnectedEgressInterfaceUnavailable "resolver returned an invalid IPv4 address for $dns"
    jq -e 'all(.[]; contains(":"))' <<<"$ipv6" >/dev/null ||
      diene_die ConnectedEgressInterfaceUnavailable "resolver returned an invalid IPv6 address for $dns"
    jq -e --argjson v4 "$ipv4" --argjson v6 "$ipv6" \
      '(($v4 | length) > 0) or (($v6 | length) > 0)' <<<null >/dev/null ||
      diene_die ConnectedEgressInterfaceUnavailable "declared endpoint $dns did not resolve before policy activation"
    resolved=$(jq -cn --argjson old "$resolved" --argjson entry "$entry" \
      --argjson v4 "$ipv4" --argjson v6 "$ipv6" \
      '$old + [$entry + {addresses:{ipv4:$v4,ipv6:$v6}}]')
  done < <(jq -c '.entries[]' "$contract")
  jq --argjson entries "$resolved" '. + {resolvedEntries:$entries}' "$contract" |
    diene_write_json "$output"
}

diene_l7_enforcer_apply() {
  local resolved=${1:?resolved egress contract required}
  local evidence=${2:?L7 evidence required}
  [[ $(diene_policy_mode "$DIENE_LANE") == allowlist ]] || return 0
  local bin=${DIENE_EGRESS_L7_ENFORCER_BIN:-}
  [[ -n $bin ]] || diene_die ConnectedEgressInterfaceUnavailable 'L7 enforcer is absent'
  diene_require_command "$bin"
  "$bin" apply --profile "$(diene_egress_profile "$DIENE_LANE")" \
    --receipt "$(diene_receipt_id)" --contract "$resolved" --evidence "$evidence" ||
    diene_die ConnectedEgressInterfaceUnavailable 'L7 egress enforcement did not arm'
  jq -e '
    .outcome == "Pass" and .dnsBound == true and .sniBound == true and
    .methodsBound == true and .defaultDenied == true
  ' "$evidence" >/dev/null ||
    diene_die ConnectedEgressInterfaceUnavailable 'L7 enforcer did not attest the complete declaration boundary'
  DIENE_L7_EGRESS_ARMED=true
  DIENE_L7_EGRESS_EVIDENCE=$evidence
  export DIENE_L7_EGRESS_ARMED DIENE_L7_EGRESS_EVIDENCE
}

diene_egress_probe_required_ids() {
  case ${1:?probe scope required} in
    preexisting-open) jq -cn '["preexisting-flow-established"]' ;;
    preexisting-transition) jq -cn '["preexisting-flow-transition-denial"]' ;;
    host) jq -cn '["host-metadata-denial","host-arbitrary-https-denial"]' ;;
    pod) jq -cn '["pod-metadata-denial","pod-arbitrary-https-denial","pod-dns-denial"]' ;;
    *) diene_die InterimPolicyUnavailable "unknown hostile probe scope $1" ;;
  esac
}

diene_egress_probe_transcript_path() {
  local scope=${1:?probe scope required}
  diene_egress_probe_required_ids "$scope" >/dev/null
  local staging=${DIENE_EVIDENCE_STAGING:-}
  [[ $staging == /* && -d $staging && ! -L $staging ]] ||
    diene_die InterimPolicyUnavailable \
      'configured hostile probes require an absolute driver-owned evidence staging directory'
  local dir="$staging/egress-probe"
  install -d -m 0700 "$dir"
  printf '%s/%s.json\n' "$dir" "$scope"
}

diene_consume_egress_probe_transcript() {
  local scope=${1:?probe scope required}
  local transcript=${2:?probe transcript required}
  [[ -s $transcript && -f $transcript && ! -L $transcript ]] ||
    diene_die InterimPolicyUnavailable \
      "configured $scope hostile probe emitted no regular non-empty transcript"
  local expected profile receipt observations
  expected=$(diene_egress_probe_required_ids "$scope")
  profile=$(diene_egress_profile "$DIENE_LANE")
  receipt=$(diene_receipt_id)
  observations=$(jq -ce --arg scope "$scope" --arg profile "$profile" \
    --arg cluster "$DIENE_NSC_CLUSTER_ID" --arg receipt "$receipt" \
    --argjson expected "$expected" '
      select(
        type == "object" and
        (keys == ["apiVersion","clusterId","observations","profileId","receiptId","scope"]) and
        .apiVersion == "diene.atomi.cloud/ci-egress-probe/v1" and
        .scope == $scope and .profileId == $profile and .clusterId == $cluster and
        .receiptId == $receipt and (.observations | type == "array") and
        ([.observations[].id] | sort) == ($expected | sort) and
        all(.observations[];
          type == "object" and (keys == ["id","outcome","reasonCode","required"]) and
          .outcome == "Pass" and .required == true and
          (($scope == "preexisting-open" and
              .reasonCode == "AdapterObservedFlowEstablished") or
            ($scope != "preexisting-open" and
              .reasonCode == "AdapterObservedDenial")))
      ) | .observations
    ' "$transcript") ||
    diene_die InterimPolicyUnavailable \
      "configured $scope hostile probe transcript has the wrong shape, binding, IDs, or verdict"
  printf '%s\n' "$observations"
}

diene_run_egress_probe_adapter() {
  local scope=${1:?probe scope required}
  local image=${2:-}
  local probe_bin=${DIENE_EGRESS_PROBE_BIN:-}
  [[ -n $probe_bin ]] || diene_die InterimPolicyUnavailable 'hostile probe adapter is absent'
  diene_require_command "$probe_bin"
  local transcript staging profile receipt
  transcript=$(diene_egress_probe_transcript_path "$scope")
  staging=${DIENE_EVIDENCE_STAGING:?evidence staging required}
  profile=$(diene_egress_profile "$DIENE_LANE")
  receipt=$(diene_receipt_id)
  rm -f -- "$transcript"
  : >>"$staging/stdout"
  : >>"$staging/stderr"
  chmod 0600 "$staging/stdout" "$staging/stderr"
  local -a argv=("$probe_bin" --scope "$scope" --profile "$profile" \
    --cluster-id "$DIENE_NSC_CLUSTER_ID" --receipt "$receipt" --transcript "$transcript")
  if [[ $scope == pod ]]; then
    [[ -n $image ]] || diene_die InterimPolicyUnavailable 'pod hostile probe image is absent'
    argv+=(--image "$image")
  fi
  "${argv[@]}" >>"$staging/stdout" 2>>"$staging/stderr" ||
    diene_die InterimPolicyUnavailable "configured $scope hostile probe failed"
  diene_consume_egress_probe_transcript "$scope" "$transcript"
}

diene_preflow_start() {
  local probe_bin=${DIENE_EGRESS_PROBE_BIN:-}
  if [[ -n $probe_bin ]]; then
    diene_run_egress_probe_adapter preexisting-open >/dev/null ||
      diene_die InterimPolicyUnavailable \
        'configured pre-existing-flow open probe did not produce valid evidence'
    DIENE_PREFLOW_ADAPTER=true
    export DIENE_PREFLOW_ADAPTER
    return 0
  fi
  diene_require_command nc
  diene_require_command ss
  local host=${DIENE_HOSTILE_PROBE_IPV4:-1.1.1.1}
  local port=${DIENE_HOSTILE_PROBE_PORT:-80}
  [[ $host =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ && $port =~ ^[1-9][0-9]{0,4}$ ]] ||
    diene_die InterimPolicyUnavailable 'hostile transition endpoint is invalid'
  coproc DIENE_PREFLOW_NC { nc -w 8 "$host" "$port"; }
  DIENE_PREFLOW_PID=$!
  DIENE_PREFLOW_READ_FD=${DIENE_PREFLOW_NC[0]}
  DIENE_PREFLOW_WRITE_FD=${DIENE_PREFLOW_NC[1]}
  DIENE_PREFLOW_HOST=$host
  DIENE_PREFLOW_ADAPTER=false
  export DIENE_PREFLOW_PID DIENE_PREFLOW_READ_FD DIENE_PREFLOW_WRITE_FD \
    DIENE_PREFLOW_HOST DIENE_PREFLOW_ADAPTER
  local waited=0
  while ((waited < 20)); do
    ss -Htn state established dst "$host:$port" | grep . >/dev/null && return 0
    kill -0 "$DIENE_PREFLOW_PID" 2>/dev/null || break
    sleep 0.1
    waited=$((waited + 1))
  done
  kill "$DIENE_PREFLOW_PID" 2>/dev/null || true
  diene_die InterimPolicyUnavailable 'hostile pre-policy TCP flow could not be established for the transition probe'
}

diene_preflow_finish() {
  if [[ ${DIENE_PREFLOW_ADAPTER:-false} == true ]]; then
    DIENE_PREFLOW_TRANSITION_RESULTS=$(diene_run_egress_probe_adapter preexisting-transition) ||
      diene_die InterimPolicyUnavailable \
        'configured pre-existing-flow transition probe did not produce valid denial evidence'
    return 0
  fi
  if printf 'GET / HTTP/1.0\r\nHost: forbidden.invalid\r\n\r\n' 1>&"$DIENE_PREFLOW_WRITE_FD" 2>/dev/null &&
    IFS= read -r -t 2 -n 1 -u "$DIENE_PREFLOW_READ_FD"; then
    kill "$DIENE_PREFLOW_PID" 2>/dev/null || true
    wait "$DIENE_PREFLOW_PID" 2>/dev/null || true
    diene_die InterimPolicyUnavailable 'a pre-existing hostile TCP flow remained usable after policy activation'
  fi
  kill "$DIENE_PREFLOW_PID" 2>/dev/null || true
  wait "$DIENE_PREFLOW_PID" 2>/dev/null || true
  DIENE_PREFLOW_TRANSITION_RESULTS=$(jq -cn '[
    {id:"preexisting-flow-transition-denial",outcome:"Pass",
     reasonCode:"NoGrandfatheredExternalFlow",required:true}
  ]')
}

diene_policy_exec() {
  "$@" || diene_die InterimPolicyUnavailable "policy command failed: $1"
}

diene_policy_hook_present() {
  local binary=${1:?binary required} base=${2:?base chain required} chain=${3:?receipt chain required}
  "$binary" -w 5 -S "$base" 2>/dev/null | grep -Fx -- "-A $base -j $chain" >/dev/null
}

# Idempotent exact cleanup for both complete policies and partially installed
# transactions. Absence is checked for every known receipt-scoped hook/chain;
# unrelated host rules are never flushed or rewritten.
diene_remove_policy_artifacts() {
  local iptables_bin=${1:?iptables required} ip6tables_bin=${2:?ip6tables required}
  local out_chain=${3:?output chain required} forward_chain=${4:?forward chain required}
  local out6_chain=${5:?IPv6 output chain required} forward6_chain=${6:?IPv6 forward chain required}
  local remove_l7=${7:-false} failed=0 binary base chain out forward
  for binary in "$iptables_bin" "$ip6tables_bin"; do
    if [[ $binary != "$iptables_bin" ]] && ! command -v "$binary" >/dev/null 2>&1; then continue; fi
    if [[ $binary == "$iptables_bin" ]]; then
      out=$out_chain
      forward=$forward_chain
    else
      out=$out6_chain
      forward=$forward6_chain
    fi
    for base in OUTPUT FORWARD; do
      chain=$out
      [[ $base != FORWARD ]] || chain=$forward
      if diene_policy_hook_present "$binary" "$base" "$chain"; then
        "$binary" -w 5 -D "$base" -j "$chain" || failed=1
      fi
    done
    for chain in "$out" "$forward"; do
      if "$binary" -w 5 -S "$chain" >/dev/null 2>&1; then
        "$binary" -w 5 -F "$chain" || failed=1
        "$binary" -w 5 -X "$chain" || failed=1
      fi
    done
  done
  if [[ $remove_l7 == true ]]; then
    "${DIENE_EGRESS_L7_ENFORCER_BIN:?}" remove --profile "$(diene_egress_profile "$DIENE_LANE")" \
      --receipt "$(diene_receipt_id)" || failed=1
  fi
  for base in OUTPUT FORWARD; do
    chain=$out_chain
    [[ $base != FORWARD ]] || chain=$forward_chain
    diene_policy_hook_present "$iptables_bin" "$base" "$chain" && failed=1
  done
  "$iptables_bin" -w 5 -S "$out_chain" >/dev/null 2>&1 && failed=1
  "$iptables_bin" -w 5 -S "$forward_chain" >/dev/null 2>&1 && failed=1
  if command -v "$ip6tables_bin" >/dev/null 2>&1; then
    for base in OUTPUT FORWARD; do
      chain=$out6_chain
      [[ $base != FORWARD ]] || chain=$forward6_chain
      diene_policy_hook_present "$ip6tables_bin" "$base" "$chain" && failed=1
    done
    "$ip6tables_bin" -w 5 -S "$out6_chain" >/dev/null 2>&1 && failed=1
    "$ip6tables_bin" -w 5 -S "$forward6_chain" >/dev/null 2>&1 && failed=1
  fi
  ((failed == 0))
}

# The fixed numeric kernel socket read. The absolute iproute2 path is written
# literally and there is deliberately no variable or environment seam for it: a
# PATH-resolved or BusyBox `ss` is not the measured tool and must never be able
# to supply an orchestration tuple.
#
# No `state established` filter is used on purpose. iproute2 drops the State
# column whenever a state filter is supplied, which would leave the established
# claim resting on the filter argument instead of on an observed value. This form
# keeps the State column, so the parser reads ESTAB from the table itself.
diene_orchestration_ss_observation() {
  diene_require_command /sbin/ss
  /sbin/ss -H -n -t -4
}

# Stable relative name of the retained same-session socket observation inside the
# run's evidence staging tree. The name is fixed so a proof-bundle consumer can
# locate the exact bytes the bound policy tuple was derived from.
DIENE_ORCHESTRATION_OBSERVATION_RELPATH=orchestration/ss-observation.txt

# Absolute path of that artifact, using the same driver-owned staging safety the
# hostile-probe transcripts already require.
diene_orchestration_observation_path() {
  local staging=${DIENE_EVIDENCE_STAGING:-}
  [[ $staging == /* && -d $staging && ! -L $staging ]] ||
    diene_die InterimPolicyUnavailable \
      'the retained orchestration observation requires an absolute driver-owned evidence staging directory'
  local dir="$staging/${DIENE_ORCHESTRATION_OBSERVATION_RELPATH%/*}"
  # A symlinked component would silently place same-session evidence outside the
  # driver-owned tree while still reporting success, so the directory must be a
  # real directory both before and after it is created.
  [[ ! -L $dir ]] ||
    diene_die InterimPolicyUnavailable \
      'the orchestration observation directory is a symlink'
  install -d -m 0700 "$dir" ||
    diene_die InterimPolicyUnavailable \
      'the orchestration observation directory could not be created'
  [[ -d $dir && ! -L $dir ]] ||
    diene_die InterimPolicyUnavailable \
      'the orchestration observation directory is not a real driver-owned directory'
  printf '%s/%s\n' "$staging" "$DIENE_ORCHESTRATION_OBSERVATION_RELPATH"
}

# Runs the fixed reader exactly once and atomically retains its exact stdout as a
# regular mode-0600 artifact. The parser then consumes those retained bytes, so
# the tuple written into the rules and the bytes kept in the proof bundle are one
# observation rather than two separate reads of a table that can change between
# them. Command, create, write, rename, or mode failure refuses here, which is
# before any chain or hook exists.
diene_retain_orchestration_observation() {
  local target=${1:?observation artifact required}
  local tmp="$target.tmp.$$"
  # Refuse an unsafe target before anything is written. `mv file dir` would move
  # the temporary file *into* an existing directory at the target path and report
  # success, and a symlinked target would publish through the link, so neither
  # may reach the publish step.
  [[ ! -e $target || (-f $target && ! -L $target) ]] ||
    diene_die InterimPolicyUnavailable \
      'the orchestration observation path is not a regular file'
  rm -f -- "$tmp" ||
    diene_die InterimPolicyUnavailable 'a stale orchestration observation could not be cleared'
  # The shell creates the redirection target before the reader runs, so every
  # failure path below removes the partial file first. Otherwise a refusal would
  # leave a stray temporary artifact in the run's evidence tree.
  (
    umask 077
    diene_orchestration_ss_observation >"$tmp"
  ) || {
    rm -f -- "$tmp"
    diene_die InterimPolicyUnavailable \
      'the fixed numeric kernel socket observation could not be taken or retained'
  }
  [[ -f $tmp && ! -L $tmp ]] || {
    rm -f -- "$tmp"
    diene_die InterimPolicyUnavailable \
      'the retained orchestration observation is not a regular file'
  }
  chmod 0600 -- "$tmp" || {
    rm -f -- "$tmp"
    diene_die InterimPolicyUnavailable \
      'the retained orchestration observation could not be sealed'
  }
  mv -f -- "$tmp" "$target" || {
    rm -f -- "$tmp"
    diene_die InterimPolicyUnavailable \
      'the retained orchestration observation could not be published'
  }
  [[ -f $target && ! -L $target && $(stat -c %a -- "$target") == 600 ]] ||
    diene_die InterimPolicyUnavailable \
      'the published orchestration observation is not a regular mode-0600 artifact'
}

# Pure parser for one numeric kernel socket observation supplied on stdin.
# Prints "<client-ip> <client-port> <server-ip> <server-port> <selected-count>".
#
# Only iproute2's headerless five-column form is accepted; any other row shape
# is a refusal rather than a skipped line. A row is a candidate only when its
# observed state is exactly ESTAB and its local endpoint port is exactly 22, so a
# BusyBox `ESTABLISHED` spelling, a header row, a TIME-WAIT or SYN-SENT socket,
# and every other port contribute nothing. Exactly one candidate may exist; zero,
# multiple, IPv6, wildcard, hostname, or service-name observations refuse.
# Nothing widens the exception beyond that single flow: no conntrack state class,
# subnet, gateway, route, or public endpoint is derived.
diene_parse_orchestration_ss_observation() {
  local line state recvq sendq local_endpoint peer_endpoint excess
  local local_address local_port peer_address peer_port flow_count=0
  local client='' client_port='' server='' server_port='' selected_row=''
  while IFS= read -r line || [[ -n $line ]]; do
    [[ -n ${line//[[:space:]]/} ]] || continue
    read -r state recvq sendq local_endpoint peer_endpoint excess <<<"$line"
    [[ -z ${excess:-} && -n $state && -n $recvq && -n $sendq &&
      -n $local_endpoint && -n $peer_endpoint ]] ||
      diene_die InterimPolicyUnavailable \
        'the kernel socket observation is not the exact headerless five-column form'
    [[ $state == ESTAB ]] || continue
    [[ $recvq =~ ^[0-9]+$ && $sendq =~ ^[0-9]+$ ]] ||
      diene_die InterimPolicyUnavailable \
        'the established kernel socket row does not carry numeric queue depths'
    [[ ${local_endpoint##*:} == 22 ]] || continue
    local_address=${local_endpoint%:*}
    local_port=${local_endpoint##*:}
    peer_address=${peer_endpoint%:*}
    peer_port=${peer_endpoint##*:}
    { diene_ipv4_valid "$local_address" && [[ $local_address != 0.0.0.0 ]] &&
      diene_ipv4_valid "$peer_address" && [[ $peer_address != 0.0.0.0 ]] &&
      diene_tcp_port_valid "$peer_port"; } ||
      diene_die InterimPolicyUnavailable \
        'the observed port 22 socket is not a concrete in-range IPv4 client/server pair'
    client=$peer_address
    client_port=$peer_port
    server=$local_address
    server_port=$local_port
    selected_row=$line
    flow_count=$((flow_count + 1))
  done
  ((flow_count == 1)) ||
    diene_die InterimPolicyUnavailable \
      "the kernel socket table yielded $flow_count established IPv4 port 22 orchestration flows, not exactly one"
  # The selected count is printed rather than merely asserted so the transcript
  # can bind a measured value. The selected row is printed last, verbatim and
  # unquoted, so a reviewer can locate the exact line of the retained artifact
  # the bound tuple came from instead of having to re-run this parser.
  printf '%s %s %s %s %s %s\n' \
    "$client" "$client_port" "$server" "$server_port" "$flow_count" "$selected_row"
}

# Exactly one orchestration transport observation, printed as one compact JSON
# object carrying the source, the canonical selected tuple, the selected-flow
# count, a deterministic digest of the exact admitted observation, and, for the
# kernel-socket source, the stable relative name of the retained bytes.
#
# The SSH environment stays the primary source. If the variable is set at all it
# must validate exactly, so neither an empty nor a malformed value can fall
# back, and `/sbin/ss` is then executed zero times. Only a completely unset
# variable permits the fixed numeric kernel socket read, which is executed
# exactly once and retained before it is parsed. Both sources yield the same
# exact four values and the same port 22 server endpoint; every degenerate
# observation fails before policy mutation.
diene_observe_orchestration_ssh_tuple() {
  local client client_port server server_port extra
  local flow_count source digest artifact artifact_relpath='' parsed selected_row
  local strict_tuple='^[0-9.]+ [0-9]+ [0-9.]+ [0-9]+$'
  if [[ -n ${SSH_CONNECTION+set} ]]; then
    # The whole value must be exactly one line of four space-separated numeric
    # fields. A line read alone would silently accept a valid-looking first line
    # followed by an injected second row, and a tab would smuggle extra fields.
    [[ $SSH_CONNECTION =~ $strict_tuple ]] ||
      diene_die InterimPolicyUnavailable \
        'the active orchestration SSH 4-tuple is not exactly one line of four numeric fields'
    read -r client client_port server server_port extra <<<"$SSH_CONNECTION"
    { [[ -z ${extra:-} ]] && diene_ipv4_valid "$client" && [[ $client != 0.0.0.0 ]] &&
      diene_ipv4_valid "$server" && [[ $server != 0.0.0.0 ]] &&
      diene_tcp_port_valid "$client_port" && [[ $server_port == 22 ]]; } ||
      diene_die InterimPolicyUnavailable \
        'the active orchestration SSH 4-tuple is unavailable, non-IPv4, or not a port 22 server endpoint'
    source=ssh-environment
    flow_count=1
    # The admitted one-line value is itself the whole observation, so it is both
    # the selected row and the deterministic digest input. No artifact is
    # retained because no kernel socket table was read.
    selected_row=$SSH_CONNECTION
    digest=$(diene_sha256_text "$SSH_CONNECTION") || exit $?
  else
    # Every step below propagates its own refusal exit code immediately. A
    # command substitution does not trip `set -e` in the caller on its own, so
    # without these guards a failed path, retention, hash, or parse would carry
    # an empty value forward into the next step instead of refusing here.
    artifact=$(diene_orchestration_observation_path) || exit $?
    diene_retain_orchestration_observation "$artifact"
    artifact_relpath=$DIENE_ORCHESTRATION_OBSERVATION_RELPATH
    digest=$(diene_file_digest "$artifact") || exit $?
    # The retained bytes are the parser's only input: no second observation.
    parsed=$(diene_parse_orchestration_ss_observation <"$artifact") || exit $?
    # The selected row is the unquoted remainder, so it survives its own spaces.
    read -r client client_port server server_port flow_count selected_row <<<"$parsed"
    source=kernel-ss
  fi
  jq -cn --arg source "$source" --arg client "$client" --argjson clientPort "$client_port" \
    --arg server "$server" --argjson serverPort "$server_port" \
    --argjson flowCount "$flow_count" --arg digest "$digest" \
    --arg selectedRow "$selected_row" \
    --arg artifact "$artifact_relpath" '
      {source:$source,
       tuple:{clientAddress:$client,clientPort:$clientPort,
              serverAddress:$server,serverPort:$serverPort},
       flowCount:$flowCount,selectedRow:$selectedRow,observationDigest:$digest,
       observationArtifact:(if $artifact == "" then null else $artifact end)}' ||
    diene_die InterimPolicyUnavailable \
      'the orchestration transport observation could not be bound'
}

diene_apply_interim_policy() {
  local resolved=${1:?resolved egress contract required}
  local transcript=${2:?policy transcript required}
  local l7_evidence=${3:?L7 evidence path required}
  diene_require_trusted_runtime_context
  diene_require_safe_id cluster_id "${DIENE_NSC_CLUSTER_ID:-}"
  diene_require_command jq
  diene_require_command "${DIENE_KUBECTL_BIN:-kubectl}"
  local iptables_bin=${DIENE_IPTABLES_BIN:-/sbin/iptables}
  local ip6tables_bin=${DIENE_IP6TABLES_BIN:-/sbin/ip6tables}
  diene_require_command "$iptables_bin"
  "$iptables_bin" --version | grep -F nf_tables >/dev/null ||
    diene_die InterimPolicyUnavailable 'iptables is not using the measured nf_tables backend'

  local hash out_chain forward_chain out6_chain forward6_chain
  hash=$(printf '%s' "$(diene_receipt_id)" | sha256sum | cut -c1-10)
  out_chain="DIO_$hash"
  forward_chain="DIF_$hash"
  out6_chain="DI6O_$hash"
  forward6_chain="DI6F_$hash"
  local kubectl_bin=${DIENE_KUBECTL_BIN:-kubectl}
  local pod_cidr pod6_cidrs service_cidr nodes_json
  nodes_json=$($kubectl_bin get nodes -o json) ||
    diene_die InterimPolicyUnavailable 'built-in k3s node topology is unavailable'
  pod_cidr=$(jq -er '.items | select(length == 1) | .[0].spec.podCIDR |
    select(type == "string" and contains(":") == false)' <<<"$nodes_json") ||
    diene_die InterimPolicyUnavailable 'one observed IPv4 pod CIDR is required'
  pod6_cidrs=$(jq -c '[.items[0].spec.podCIDRs[]? | select(type == "string" and contains(":"))]' \
    <<<"$nodes_json")
  [[ -f ${DIENE_PREFLIGHT_EVIDENCE:-} ]] ||
    diene_die InterimPolicyUnavailable 'runner preflight evidence is required before policy activation'
  service_cidr=$(jq -er '.network.serviceCidrs | select(length == 1) | .[0]' "$DIENE_PREFLIGHT_EVIDENCE") ||
    diene_die InterimPolicyUnavailable 'one observed service CIDR is required'

  # The transport observation is taken, retained, and bound before any chain or
  # hook exists, so every refusal above leaves no policy artifact behind.
  # Only the four rule values are unpacked here; the source, count, digest, and
  # retained-artifact name are bound into the transcript straight from the same
  # observation object, so the rules and the proof cannot describe different
  # flows.
  local ssh_client ssh_client_port ssh_server ssh_server_port observation rule_tuple
  observation=$(diene_observe_orchestration_ssh_tuple)
  rule_tuple=$(jq -er '[.tuple.clientAddress,.tuple.clientPort,
    .tuple.serverAddress,.tuple.serverPort] | @tsv' <<<"$observation") ||
    diene_die InterimPolicyUnavailable 'the orchestration transport observation is unreadable'
  read -r ssh_client ssh_client_port ssh_server ssh_server_port <<<"$rule_tuple"

  local ipv6_disabled=0 ipv6_armed=false policy_mode
  local ipv6_disable_path=${DIENE_IPV6_DISABLE_PATH:-/proc/sys/net/ipv6/conf/all/disable_ipv6}
  local l7_attempted=$l7_evidence.attempted transaction_rc=0
  [[ ! -r $ipv6_disable_path ]] || read -r ipv6_disabled <"$ipv6_disable_path"
  policy_mode=$(diene_policy_mode "$DIENE_LANE")
  rm -f -- "$transcript" "$l7_attempted"
  if [[ $ipv6_disabled != 1 ]]; then
    diene_require_command "$ip6tables_bin"
    "$ip6tables_bin" --version | grep -F nf_tables >/dev/null ||
      diene_die InterimPolicyUnavailable 'ip6tables is not using the measured nf_tables backend'
    jq -e 'type == "array" and length >= 1' <<<"$pod6_cidrs" >/dev/null ||
      diene_die InterimPolicyUnavailable \
        'host IPv6 is enabled but no IPv6 pod CIDR was observed; refusing an unenforced IPv6 forwarding path'
    ipv6_armed=true
  fi
  (
    diene_policy_exec "$iptables_bin" -w 5 -N "$out_chain"
    diene_policy_exec "$iptables_bin" -w 5 -N "$forward_chain"
    diene_policy_exec "$iptables_bin" -w 5 -A "$out_chain" -d 169.254.169.254/32 -j REJECT
    diene_policy_exec "$iptables_bin" -w 5 -A "$out_chain" -p tcp -s "$ssh_server" -d "$ssh_client" \
      --sport "$ssh_server_port" --dport "$ssh_client_port" -m conntrack --ctstate ESTABLISHED -j ACCEPT
    diene_policy_exec "$iptables_bin" -w 5 -A "$out_chain" -o lo -j ACCEPT

    local internal entry address port pod6_cidr
    for internal in "$pod_cidr" "$service_cidr"; do
      diene_policy_exec "$iptables_bin" -w 5 -A "$out_chain" -d "$internal" -j ACCEPT
      diene_policy_exec "$iptables_bin" -w 5 -A "$forward_chain" -s "$pod_cidr" -d "$internal" -j ACCEPT
    done
    diene_policy_exec "$iptables_bin" -w 5 -A "$forward_chain" -s "$pod_cidr" \
      -d 169.254.169.254/32 -j REJECT
    while IFS= read -r entry; do
      port=$(jq -r '.port' <<<"$entry")
      while IFS= read -r address; do
        [[ -n $address ]] || continue
        diene_policy_exec "$iptables_bin" -w 5 -A "$out_chain" -p tcp -d "$address" --dport "$port" -j ACCEPT
        diene_policy_exec "$iptables_bin" -w 5 -A "$forward_chain" -s "$pod_cidr" \
          -p tcp -d "$address" --dport "$port" -j ACCEPT
      done < <(jq -r '.addresses.ipv4[]' <<<"$entry")
    done < <(jq -c '.resolvedEntries[]' "$resolved")
    diene_policy_exec "$iptables_bin" -w 5 -A "$out_chain" -j REJECT
    diene_policy_exec "$iptables_bin" -w 5 -A "$forward_chain" -s "$pod_cidr" -j REJECT
    diene_policy_exec "$iptables_bin" -w 5 -A "$forward_chain" -j RETURN
    diene_policy_exec "$iptables_bin" -w 5 -I OUTPUT 1 -j "$out_chain"
    diene_policy_exec "$iptables_bin" -w 5 -I FORWARD 1 -j "$forward_chain"

    if [[ $ipv6_armed == true ]]; then
      diene_policy_exec "$ip6tables_bin" -w 5 -N "$out6_chain"
      diene_policy_exec "$ip6tables_bin" -w 5 -N "$forward6_chain"
      diene_policy_exec "$ip6tables_bin" -w 5 -A "$out6_chain" -o lo -j ACCEPT
      while IFS= read -r pod6_cidr; do
        [[ -n $pod6_cidr ]] || continue
        diene_policy_exec "$ip6tables_bin" -w 5 -A "$out6_chain" -d "$pod6_cidr" -j ACCEPT
        diene_policy_exec "$ip6tables_bin" -w 5 -A "$forward6_chain" -s "$pod6_cidr" -d "$pod6_cidr" -j ACCEPT
      done < <(jq -r '.[]' <<<"$pod6_cidrs")
      while IFS= read -r entry; do
        port=$(jq -r '.port' <<<"$entry")
        while IFS= read -r address; do
          [[ -n $address ]] || continue
          diene_policy_exec "$ip6tables_bin" -w 5 -A "$out6_chain" -p tcp -d "$address" --dport "$port" -j ACCEPT
          while IFS= read -r pod6_cidr; do
            [[ -n $pod6_cidr ]] || continue
            diene_policy_exec "$ip6tables_bin" -w 5 -A "$forward6_chain" -s "$pod6_cidr" \
              -p tcp -d "$address" --dport "$port" -j ACCEPT
          done < <(jq -r '.[]' <<<"$pod6_cidrs")
        done < <(jq -r '.addresses.ipv6[]' <<<"$entry")
      done < <(jq -c '.resolvedEntries[]' "$resolved")
      diene_policy_exec "$ip6tables_bin" -w 5 -A "$out6_chain" -j REJECT
      while IFS= read -r pod6_cidr; do
        [[ -n $pod6_cidr ]] || continue
        diene_policy_exec "$ip6tables_bin" -w 5 -A "$forward6_chain" -s "$pod6_cidr" -j REJECT
      done < <(jq -r '.[]' <<<"$pod6_cidrs")
      diene_policy_exec "$ip6tables_bin" -w 5 -A "$forward6_chain" -j RETURN
      diene_policy_exec "$ip6tables_bin" -w 5 -I OUTPUT 1 -j "$out6_chain"
      diene_policy_exec "$ip6tables_bin" -w 5 -I FORWARD 1 -j "$forward6_chain"
    fi

    [[ $policy_mode != allowlist ]] || : >"$l7_attempted"
    diene_l7_enforcer_apply "$resolved" "$l7_evidence"
    local rules_file rules_digest
    rules_file=$(mktemp "${RUNNER_TEMP:-/tmp}/diene-iptables.XXXXXX") ||
      diene_die InterimPolicyUnavailable 'could not allocate rules transcript'
    {
      diene_policy_exec "$iptables_bin" -w 5 -S "$out_chain"
      diene_policy_exec "$iptables_bin" -w 5 -S "$forward_chain"
      [[ $ipv6_armed != true ]] || diene_policy_exec "$ip6tables_bin" -w 5 -S "$out6_chain"
      [[ $ipv6_armed != true ]] || diene_policy_exec "$ip6tables_bin" -w 5 -S "$forward6_chain"
    } >"$rules_file" || diene_die InterimPolicyUnavailable 'could not capture the exact ruleset'
    if grep -F -- '--ctstate ESTABLISHED,RELATED' "$rules_file" >/dev/null; then
      rm -f -- "$rules_file"
      diene_die InterimPolicyUnavailable 'ruleset contains a blanket established-flow exemption'
    fi
    rules_digest=$(diene_file_digest "$rules_file") ||
      diene_die InterimPolicyUnavailable 'rules transcript digest failed'
    rm -f -- "$rules_file"
    jq -n --arg outputChain "$out_chain" --arg forwardChain "$forward_chain" \
      --arg output6Chain "$out6_chain" --arg forward6Chain "$forward6_chain" \
      --arg mode "$policy_mode" --arg profile "$(diene_egress_profile "$DIENE_LANE")" \
      --arg clusterId "$DIENE_NSC_CLUSTER_ID" --arg podCidr "$pod_cidr" \
      --arg serviceCidr "$service_cidr" --arg rulesDigest "$rules_digest" \
      --argjson orchestration "$observation" \
      --argjson ipv6Armed "$ipv6_armed" --argjson pod6Cidrs "$pod6_cidrs" '
        {mechanism:"interim-in-guest-iptables-nft",backend:"nf_tables",
         platformStatus:"platform per-instance policy pending (support ask #4)",
         trustBoundary:"trusted-generated-content",outputChain:$outputChain,forwardChain:$forwardChain,
         output6Chain:$output6Chain,forward6Chain:$forward6Chain,ipv6Armed:$ipv6Armed,
         mode:$mode,profileId:$profile,clusterId:$clusterId,podCidr:$podCidr,pod6Cidrs:$pod6Cidrs,
         serviceCidr:$serviceCidr,rulesDigest:$rulesDigest,applied:true,
         orchestrationException:"exact-ssh-4-tuple",
         orchestrationTupleSource:$orchestration.source,
         orchestrationTuple:$orchestration.tuple,
         orchestrationFlowCount:$orchestration.flowCount,
         orchestrationSelectedRow:$orchestration.selectedRow,
         orchestrationObservationDigest:$orchestration.observationDigest,
         orchestrationObservationArtifact:$orchestration.observationArtifact}' |
        diene_write_json "$transcript" ||
      diene_die InterimPolicyUnavailable 'policy transcript finalization failed'
  ) || transaction_rc=$?
  if ((transaction_rc != 0)); then
    local remove_l7=false
    [[ ! -e $l7_attempted ]] || remove_l7=true
    diene_remove_policy_artifacts "$iptables_bin" "$ip6tables_bin" "$out_chain" "$forward_chain" \
      "$out6_chain" "$forward6_chain" "$remove_l7" ||
      diene_die InterimPolicyRollbackFailed 'partial policy installation could not prove complete rollback'
    rm -f -- "$l7_attempted"
    diene_die InterimPolicyUnavailable 'partial policy installation was completely rolled back'
  fi

  DIENE_INTERIM_POLICY_OUTPUT_CHAIN=$out_chain
  DIENE_INTERIM_POLICY_FORWARD_CHAIN=$forward_chain
  DIENE_INTERIM_POLICY_OUTPUT6_CHAIN=$out6_chain
  DIENE_INTERIM_POLICY_FORWARD6_CHAIN=$forward6_chain
  DIENE_INTERIM_POLICY_IPV6_ARMED=$ipv6_armed
  if [[ $policy_mode == allowlist ]]; then
    DIENE_L7_EGRESS_ARMED=true
    DIENE_L7_EGRESS_EVIDENCE=$l7_evidence
    export DIENE_L7_EGRESS_ARMED DIENE_L7_EGRESS_EVIDENCE
  fi
  rm -f -- "$l7_attempted"
  export DIENE_INTERIM_POLICY_OUTPUT_CHAIN DIENE_INTERIM_POLICY_FORWARD_CHAIN \
    DIENE_INTERIM_POLICY_OUTPUT6_CHAIN DIENE_INTERIM_POLICY_FORWARD6_CHAIN \
    DIENE_INTERIM_POLICY_IPV6_ARMED
}

diene_remove_interim_policy() {
  [[ -n ${DIENE_INTERIM_POLICY_OUTPUT_CHAIN:-} ]] || return 0
  local remove_l7=false
  [[ ${DIENE_L7_EGRESS_ARMED:-false} != true ]] || remove_l7=true
  diene_remove_policy_artifacts "${DIENE_IPTABLES_BIN:-/sbin/iptables}" \
    "${DIENE_IP6TABLES_BIN:-/sbin/ip6tables}" "$DIENE_INTERIM_POLICY_OUTPUT_CHAIN" \
    "$DIENE_INTERIM_POLICY_FORWARD_CHAIN" "$DIENE_INTERIM_POLICY_OUTPUT6_CHAIN" \
    "$DIENE_INTERIM_POLICY_FORWARD6_CHAIN" "$remove_l7" || return 1
  unset DIENE_INTERIM_POLICY_OUTPUT_CHAIN DIENE_INTERIM_POLICY_FORWARD_CHAIN
  unset DIENE_INTERIM_POLICY_OUTPUT6_CHAIN DIENE_INTERIM_POLICY_FORWARD6_CHAIN
  DIENE_INTERIM_POLICY_IPV6_ARMED=false
  DIENE_L7_EGRESS_ARMED=false
  export DIENE_INTERIM_POLICY_IPV6_ARMED DIENE_L7_EGRESS_ARMED
}

diene_verify_hostile_egress() {
  local output=${1:?probe output required}
  local probe_bin results
  probe_bin=${DIENE_EGRESS_PROBE_BIN:-}
  diene_preflow_finish
  results=${DIENE_PREFLOW_TRANSITION_RESULTS:?pre-existing flow transition result required}
  if [[ -n $probe_bin ]]; then
    local host_results pod_results
    host_results=$(diene_run_egress_probe_adapter host) ||
      diene_die InterimPolicyUnavailable \
        'configured host hostile probe did not produce valid denial evidence'
    pod_results=$(diene_run_egress_probe_adapter pod "$DIENE_EGRESS_CANARY_IMAGE") ||
      diene_die InterimPolicyUnavailable \
        'configured pod hostile probe did not produce valid denial evidence'
    results=$(jq -cn --argjson transition "$results" --argjson host "$host_results" \
      --argjson pod "$pod_results" '$transition + $host + $pod') ||
      diene_die InterimPolicyUnavailable 'hostile probe observations could not be combined'
  else
    diene_require_command curl
    if curl -fsS --connect-timeout 1 --max-time 2 http://169.254.169.254/ >/dev/null 2>&1; then
      diene_die InterimPolicyUnavailable 'metadata hostile probe escaped the host OUTPUT policy'
    fi
    if curl -kfsS --connect-timeout 1 --max-time 2 "https://${DIENE_HOSTILE_PROBE_IPV4:-1.1.1.1}/" >/dev/null 2>&1; then
      diene_die InterimPolicyUnavailable 'arbitrary HTTPS hostile probe escaped the host OUTPUT policy'
    fi
    results=$(jq -c '. + [
      {id:"host-metadata-denial",outcome:"Pass",reasonCode:"ConnectionRefused",required:true},
      {id:"host-arbitrary-https-denial",outcome:"Pass",reasonCode:"ConnectionRefused",required:true}]' <<<"$results")
    local kubectl_bin=${DIENE_KUBECTL_BIN:-kubectl}
    local pod
    pod="diene-egress-$(printf '%s' "$(diene_receipt_id)" | sha256sum | cut -c1-10)"
    "$kubectl_bin" run "$pod" --restart=Never --image="$DIENE_EGRESS_CANARY_IMAGE" \
      --image-pull-policy=Never --command -- sh -ceu '
        ! wget -q -T 2 -O /dev/null http://169.254.169.254/
        ! wget -q -T 2 -O /dev/null https://1.1.1.1/
        ! wget -q -T 2 -O /dev/null https://forbidden.invalid/
      ' >/dev/null || diene_die InterimPolicyUnavailable 'could not create the actual-pod egress canary'
    "$kubectl_bin" wait --for=jsonpath='{.status.phase}'=Succeeded "pod/$pod" --timeout=30s >/dev/null || {
      "$kubectl_bin" logs "$pod" >&2 2>/dev/null || true
      "$kubectl_bin" delete pod "$pod" --wait=false >/dev/null 2>&1 || true
      diene_die InterimPolicyUnavailable 'actual-pod metadata/DNS/public probes did not all refuse'
    }
    "$kubectl_bin" delete pod "$pod" --wait=true --timeout=30s >/dev/null ||
      diene_die InterimPolicyUnavailable 'actual-pod egress canary cleanup failed'
    results=$(jq -c '. + [
      {id:"pod-metadata-denial",outcome:"Pass",reasonCode:"ForwardRefused",required:true},
      {id:"pod-arbitrary-https-denial",outcome:"Pass",reasonCode:"ForwardRefused",required:true},
      {id:"pod-dns-denial",outcome:"Pass",reasonCode:"ForwardRefused",required:true}]' <<<"$results")
  fi
  printf '%s\n' "$results" | diene_write_json "$output"
  jq -e '
    type == "array" and
    ([.[].id] | sort) == ["host-arbitrary-https-denial","host-metadata-denial",
      "pod-arbitrary-https-denial","pod-dns-denial","pod-metadata-denial",
      "preexisting-flow-transition-denial"] and
    all(.[]; .outcome == "Pass" and .required == true)
  ' "$output" >/dev/null ||
    diene_die InterimPolicyUnavailable 'hostile host/pod probe transcript is incomplete'
}

diene_verify_endpoint_law() {
  local output=${1:?endpoint evidence required}
  local kubectl_bin=${DIENE_KUBECTL_BIN:-kubectl}
  diene_require_command "$kubectl_bin"
  local ingress services gateways
  ingress=$($kubectl_bin get ingress -A -o json 2>/dev/null || printf '{"items":[]}\n')
  services=$($kubectl_bin get service -A -o json)
  gateways=$($kubectl_bin get gateway -A -o json 2>/dev/null || printf '{"items":[]}\n')
  jq -e '(.items // []) | length == 0' <<<"$ingress" >/dev/null ||
    diene_die EndpointLawViolation 'Namespace/application ingress objects are forbidden in SIT'
  jq -e '(.items // []) | all(.spec.type != "LoadBalancer" and ((.spec.externalIPs // []) | length == 0))' \
    <<<"$services" >/dev/null || diene_die EndpointLawViolation 'public or external Service binding found'
  jq -e '(.items // []) | all(((.status.addresses // []) | all(.value == "127.0.0.1" or .value == "::1")))' \
    <<<"$gateways" >/dev/null || diene_die EndpointLawViolation 'Gateway address is not loopback-only'
  jq -n '{outcome:"Pass",reasonCode:"LoopbackOnlyNoIngress",namespaceEndpointUsed:false,
    publicDnsUsed:false,wildcardBinding:false,lanBinding:false}' | diene_write_json "$output"
}

# ---------------------------------------------------------------------------
# Mandatory proof adapters not yet ratified into Garden.
# ---------------------------------------------------------------------------

diene_require_pull_proof() {
  local bin=${DIENE_PULL_PROOF_BIN:-/opt/diene/bin/diene-artifact-pull-proof}
  command -v "$bin" >/dev/null 2>&1 || [[ -x $bin ]] ||
    diene_die RequiredCoverageUnavailable \
      'target-pull requires real pull, repull, sibling denial, Secret ownership, and credential removal proof'
  printf '%s\n' "$bin"
}

diene_require_closure_verifier() {
  local bin=${DIENE_CLOSURE_VERIFY_BIN:-/opt/diene/bin/diene-closure-verify}
  command -v "$bin" >/dev/null 2>&1 || [[ -x $bin ]] ||
    diene_die ClosureAttestationInterfaceUnavailable \
      'Absol requires signature, certificate, Rekor, trust-root, and exact-set verification'
  printf '%s\n' "$bin"
}

# ---------------------------------------------------------------------------
# Declared argv execution and bounded condition polling.
# ---------------------------------------------------------------------------

diene_run_argv() {
  local manifest=${1:?manifest required}
  local selector=${2:?selector required}
  local phase=${3:?phase required}
  local scratch
  scratch=$(mktemp "${RUNNER_TEMP:-/tmp}/diene-argv.XXXXXX")
  jq -er "$selector | .${phase}[]" "$manifest" >"$scratch" ||
    diene_die InputContractInvalid "$phase argv missing"
  local -a argv=()
  mapfile -t argv <"$scratch"
  rm -f -- "$scratch"
  ((${#argv[@]} > 0)) || diene_die InputContractInvalid "$phase argv empty"
  local working_directory timeout_seconds
  working_directory=$(jq -er "$selector | .workingDirectory // \".\"" "$manifest") ||
    diene_die InputContractInvalid 'workingDirectory missing'
  timeout_seconds=$(jq -er "$selector | .timeoutSeconds | select(type == \"number\" and . >= 1 and . <= 3600)" "$manifest") ||
    diene_die InputContractInvalid 'bounded timeoutSeconds missing'
  [[ $working_directory =~ ^(\.|[A-Za-z0-9_.-]+)(/[A-Za-z0-9_.-]+)*$ && -d $working_directory ]] ||
    diene_die InputContractInvalid 'workingDirectory escapes or is absent'
  diene_require_command timeout
  printf '%q ' "${argv[@]}" >>"${DIENE_EVIDENCE_STAGING:-/dev/null}/argv" 2>/dev/null || true
  printf '\n' >>"${DIENE_EVIDENCE_STAGING:-/dev/null}/argv" 2>/dev/null || true
  local staged_out=${DIENE_EVIDENCE_STAGING:+$DIENE_EVIDENCE_STAGING/stdout}
  local staged_err=${DIENE_EVIDENCE_STAGING:+$DIENE_EVIDENCE_STAGING/stderr}
  if [[ -n $staged_out && -n $staged_err ]]; then
    (cd -- "$working_directory" && timeout --foreground --kill-after=10s "${timeout_seconds}s" \
      "${argv[@]}" </dev/null >>"$staged_out" 2>>"$staged_err")
  else
    (cd -- "$working_directory" && timeout --foreground --kill-after=10s "${timeout_seconds}s" "${argv[@]}" </dev/null)
  fi
}

diene_wait_for() {
  local bound=${1:?bound required}
  local interval=${2:?interval required}
  shift 2
  local waited=0
  while ((waited < bound)); do
    if "$@"; then
      printf '%s\n' "$waited"
      return 0
    fi
    sleep "$interval"
    waited=$((waited + interval))
  done
  printf '%s\n' "$waited"
  return 1
}
