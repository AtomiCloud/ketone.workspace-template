{ pkgs, packages }:
with packages;
{
  dev = [
    git
    pls
  ];

  lint = [
    actionlint
    gitlint
    go-task
    infralint
    kubeconform
    kyverno
    pre-commit
    sg
    shellcheck
    treefmt
  ];

  main = [
  ];

  releaser = [
    sg
  ];

  system = [
    atomiutils
    infrautils
  ];
}
