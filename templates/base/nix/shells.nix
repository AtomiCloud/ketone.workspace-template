{ pkgs, packages, env, shellHook }:
with env;
let
  pinnedNamespaceCli = {
    DIENE_NSC_BIN = "${packages.nsc}/bin/nsc";
    DIENE_NSC_IDENTITY_FILE = "${packages.nsc}/share/diene/nsc-identity.json";
  };
in
{
  default = pkgs.mkShell (pinnedNamespaceCli // {
    buildInputs = system ++ main ++ lint ++ dev;
    inherit shellHook;
  });
  ci = pkgs.mkShell (pinnedNamespaceCli // {
    buildInputs = system ++ main ++ lint;
    inherit shellHook;
  });
  cd = pkgs.mkShell (pinnedNamespaceCli // {
    buildInputs = system ++ main;
    inherit shellHook;
  });
  releaser = pkgs.mkShell (pinnedNamespaceCli // {
    buildInputs = system ++ main ++ lint ++ releaser;
    inherit shellHook;
  });
}
