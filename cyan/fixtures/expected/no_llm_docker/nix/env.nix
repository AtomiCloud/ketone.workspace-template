{ pkgs, packages }:
with packages;
{
  dev = [
    git
    pls
    skopeo
  ];

  lint = [
    actionlint
    gitlint
    go-task
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
  ];
}
