{ pkgs, packages }:
with packages;
{
  dev = [
    git
    infisical
    pls
    skopeo
  ];

  lint = [
    actionlint
    gitlint
    go-task
    infralint
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
