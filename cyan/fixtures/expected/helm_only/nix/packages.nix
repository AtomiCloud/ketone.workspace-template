{ atomi, pkgs, pkgs-2511, pkgs-unstable }:
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

    nix-2511 = (
      with pkgs-2511;
      {
        inherit
          actionlint
          git
          gitlint
          go-task
          infisical
          pre-commit
          shellcheck
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
