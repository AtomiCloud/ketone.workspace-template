{ pkgs, packages }:
with packages;
{
  dev = [
    git
    infisical
  ];

  lint = [
    actionlint
    check-jsonschema
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
    pls
  ];
}
