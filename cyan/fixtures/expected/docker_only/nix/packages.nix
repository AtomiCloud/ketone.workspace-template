{ atomi, pkgs, pkgs-2605, pkgs-unstable }:
let
  all = rec {
    atomipkgs = (
      with atomi;
      {
        inherit
          atomiutils
          infralint
          infrautils
          pls
          sg
        ;
      }
    );

    nix-2605 = (
      with pkgs-2605;
      {
        inherit
          actionlint
          git
          gitlint
          go-task
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
nix-2605 //
nix-unstable
