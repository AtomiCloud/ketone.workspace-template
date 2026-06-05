{ atomi, pkgs, pkgs-2511, pkgs-unstable }:
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

    nix-2511 = (
      with pkgs-2511;
      {
        inherit
          actionlint
          git
          gitlint
          go-task
          hadolint
          infisical
          pre-commit
          shellcheck
          skopeo
          treefmt
        ;
      }
    );

    nix-unstable = (
      with pkgs-unstable;
      {
      }
    );
  };
in
with all;
atomipkgs //
nix-2511 //
nix-unstable
