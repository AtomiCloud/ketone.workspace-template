{ pkgs, packages, env, shellHook }:
with env;
{
  default = pkgs.mkShell {
    buildInputs = system ++ main ++ lint ++ dev;
    inherit shellHook;
  };
  helm = pkgs.mkShell {
    buildInputs = system ++ lint;
    inherit shellHook;
  };
}
