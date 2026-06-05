{ pkgs, pkgs-2511, pkgs-unstable, atomi }:
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
    nix-2511 = (
      with pkgs-2511;
      {
        inherit
          git
          infisical
          treefmt
          gitlint
          shellcheck
          actionlint
          go-task
          pre-commit
          ;
      }
    );
  };
in
with all;
nix-2511 // nix-unstable // atomipkgs
