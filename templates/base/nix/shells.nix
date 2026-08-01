{ pkgs, packages, env, shellHook }:
with env;
{
  default = pkgs.mkShell {
    buildInputs = system ++ main ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux mainLinux ++ lint ++ dev;
    inherit shellHook;
  };
  ci = pkgs.mkShell {
    buildInputs = system ++ main ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux mainLinux ++ lint;
    inherit shellHook;
  };
  cd = pkgs.mkShell {
    buildInputs = system ++ main ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux mainLinux;
    inherit shellHook;
  };
  releaser = pkgs.mkShell {
    buildInputs = system ++ main ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux mainLinux ++ lint ++ releaser;
    inherit shellHook;
  };
}
