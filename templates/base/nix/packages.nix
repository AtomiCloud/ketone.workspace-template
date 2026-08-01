{ pkgs, pkgs-2605, pkgs-unstable, atomi }:
let

  # The Namespace lifecycle is implemented against this measured CLI release.
  # Keep the release archive and executable identity inside the declared shell;
  # accepting whatever `nsc` happens to be on a runner PATH is not safe enough
  # for create/upload/SSH/download/destroy semantics.
  nsc =
    let
      inherit (pkgs-2605.stdenv.hostPlatform) system;
      release = {
        x86_64-linux = {
          platform = "linux_amd64";
          hash = "sha256-suxxRscqokyVkwE1JZ3Wuool/cTa4vySNGKGrHG+oPw=";
          digest = "sha256:b2ec7146c72aa24c95930135259dd6ba8a25fdc4dae2fc92346286ac71bea0fc";
        };
        aarch64-linux = {
          platform = "linux_arm64";
          hash = "sha256-lNgnALrYUBkSgvKmOVtW6jOmfWCTc3ITD64VwzdHzWo=";
          digest = "sha256:94d82700bad850191282f2a6395b56ea33a67d60937372130fae15c33747cd6a";
        };
        aarch64-darwin = {
          platform = "darwin_arm64";
          hash = "sha256-floxGKsUhXS3ZYBdHLoWwzoFlt9Qpl9oeM9j2PF//kA=";
          digest = "sha256:7e5a3118ab148574b765805d1cba16c33a0596df50a65f6878cf63d8f17ffe40";
        };
      }.${system} or (throw "nsc 0.0.532 is unsupported on ${system}");
      version = "0.0.532";
    in
    pkgs-2605.stdenv.mkDerivation {
      pname = "nsc";
      inherit version;
      sourceRoot = ".";
      src = pkgs-2605.fetchurl {
        url = "https://github.com/namespacelabs/foundation/releases/download/v${version}/nsc_${version}_${release.platform}.tar.gz";
        inherit (release) hash;
      };
      installPhase = ''
        runHook preInstall
        mkdir -p "$out/bin" "$out/share/diene"
        for bin in nsc docker-credential-nsc bazel-credential-nsc; do
          install -m 0555 "$bin" "$out/bin/$bin"
        done
        runHook postInstall
      '';
      postFixup = ''
        # Record the final executable after stdenv's deterministic strip/fixup
        # phases, not the pre-fixup copy from the release archive.
        binary_digest="$(sha256sum "$out/bin/nsc" | awk '{print $1}')"
        printf '{"version":"v${version}","artifactDigest":"${release.digest}","binaryDigest":"sha256:%s"}\n' \
          "$binary_digest" >"$out/share/diene/nsc-identity.json"
        chmod 0444 "$out/share/diene/nsc-identity.json"
      '';
      meta = with pkgs-2605.lib; {
        description = "Pinned Namespace Cloud CLI";
        mainProgram = "nsc";
        homepage = "https://namespace.so/";
        license = licenses.asl20;
        platforms = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ];
      };
    };

  all = rec {
    atomipkgs = (
      with atomi;
      {
        inherit
          atomiutils
          pls
          sg
          ;
      }
    );
    nix-unstable = (with pkgs-unstable; { });
    nix-2605 = (
      with pkgs-2605;
      {
        inherit nsc;
        inherit
          git
          coreutils
          curl
          findutils
          gawk
          gnugrep
          gnutar
          infisical
          iproute2
          iptables
          jq
          kubectl
          netcat-openbsd
          procps
          treefmt
          gitlint
          shellcheck
          actionlint
          go-task
          pre-commit
          check-jsonschema
          yq-go
          ;
      }
    );
  };
in
with all;
nix-2605 // nix-unstable // atomipkgs
