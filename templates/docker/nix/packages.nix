{ pkgs, pkgs-2511, pkgs-unstable, atomi }:
let

  all = rec {
    nix-2511 = (
      with pkgs-2511;
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
nix-2511
