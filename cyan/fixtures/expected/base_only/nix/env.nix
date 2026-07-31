{ pkgs, packages }:
with packages;
{
  system = [
    atomiutils
    # `pls` is the single ratified lifecycle entrypoint, so it must exist in
    # every shell that runs CI scripts - not just the interactive one.
    pls
  ];

  dev = [
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
    # Repository declarations and emitted reports are validated against real
    # JSON Schemas before they are trusted.
    check-jsonschema
  ];

  releaser = [
    sg
  ];
}
