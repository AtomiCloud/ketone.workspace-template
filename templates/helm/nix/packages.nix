{ pkgs, pkgs-2511, pkgs-unstable, atomi }:
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
  };
in
with all;
atomipkgs
