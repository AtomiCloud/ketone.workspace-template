{ pkgs, packages }:
with packages;
{
  system = [
    atomiutils
  ];

  dev = [
    pls
    git
  ];

  main = [
  ];

  lint = [
    pre-commit
    treefmt
    gitlint
    shellcheck
    sg
    actionlint
    go-task
  ];

  releaser = [
    sg
  ];
}
