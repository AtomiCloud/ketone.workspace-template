{ pkgs, packages }:
with packages;
{
  dev = [
    infisical
    skopeo
  ];

  lint = [
    actionlint
    check-jsonschema
    gitlint
    go-task
    infralint
    kubeconform
    kyverno
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
    infrautils
    nsc
    pls
  ];
}
