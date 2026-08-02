{ pkgs, packages }:
with packages;
{
  dev = [
    infisical
  ];

  lint = [
    actionlint
    check-jsonschema
    gitlint
    go-task
    pkgs.ripgrep
    pre-commit
    sg
    shellcheck
    treefmt
  ];

  main = [
    git
    kubectl
  ];

  mainLinux = [
    iproute2
    pkgs.getent
  ];

  releaser = [
    sg
  ];

  system = [
    atomiutils
    nsc
    pls
  ];
}
