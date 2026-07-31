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
    check-jsonschema
    check-jsonschema
    check-jsonschema
    check-jsonschema
    check-jsonschema
    check-jsonschema
    check-jsonschema
    check-jsonschema
    check-jsonschema
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
    pls
    pls
    pls
    pls
    pls
    pls
    pls
    pls
    pls
    pls
  ];
}
