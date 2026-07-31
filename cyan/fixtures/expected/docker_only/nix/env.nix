{ pkgs, packages }:
with packages;
{
  dev = [
    git
    skopeo
  ];

  lint = [
    actionlint
    check-jsonschema
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
    pls
  ];
}
