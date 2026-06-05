{ pkgs, pkgs-2605, pkgs-unstable, atomi }:
let

  all = rec {
    nix-2605 = (
      with pkgs-2605;
      {
        inherit
          hadolint
          skopeo
          ;
      }
    );
  };
in
with all;
nix-2605
