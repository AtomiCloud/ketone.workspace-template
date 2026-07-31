{ pkgs, pkgs-2605, pkgs-unstable, atomi }:
let

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
