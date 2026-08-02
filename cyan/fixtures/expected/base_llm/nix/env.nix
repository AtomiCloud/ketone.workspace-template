{ pkgs, packages }:
with packages;
{
  system = [
    atomiutils
    # `pls` is the single ratified lifecycle entrypoint, so it must exist in
    # every shell that runs CI scripts - not just the interactive one.
    pls
    # Namespace lifecycle commands are pinned by archive hash and selected by
    # an absolute store path in shells.nix.
    nsc
  ];

  dev = [
  ];

  main = [
    # Production lifecycle scripts must resolve these from every composed
    # shell that runs them, rather than inherit whichever venue versions exist.
    git
    kubectl
  ];

  mainLinux = [
    # The Namespace guest path is Linux-only; keeping these conditional also
    # preserves the parent flake's aarch64-darwin shell evaluation.
    iproute2
    # The connected-lane DNS fallback uses getent directly.  Keep its provider
    # on the same pinned nixpkgs channel as the rest of the shell.
    pkgs.getent
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
    # The contract harness performs bounded source-surface scans with rg.
    pkgs.ripgrep
  ];

  releaser = [
    sg
  ];
}
