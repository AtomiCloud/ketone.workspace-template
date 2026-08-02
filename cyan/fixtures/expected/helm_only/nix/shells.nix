{ env, packages, pkgs, shellHook }:
with env;
{
  cd = pkgs.mkShell {
    buildInputs = main ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux mainLinux ++ system;
    inherit shellHook;
  };

  ci = pkgs.mkShell {
    buildInputs = lint ++ main ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux mainLinux ++ system;
    inherit shellHook;
  };

  default = pkgs.mkShell {
    buildInputs = dev ++ lint ++ main ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux mainLinux ++ system;
    inherit shellHook;
  };

  releaser = pkgs.mkShell {
    buildInputs = lint ++ main ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux mainLinux ++ releaser ++ system;
    inherit shellHook;
  };
}
