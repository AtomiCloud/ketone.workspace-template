{ pkgs, pkgs-2605, pkgs-unstable, atomi }:
let

  all = rec {
    atomipkgs = (
      with atomi;
      {
        inherit
          infrautils
          infralint
          ;
      }
    );
    nix-2605 = (
      with pkgs-2605;
      {
        inherit
          skopeo
          ;
      }
    );
  };
in
with all;
atomipkgs // nix-2605
