# Learnings — Plan 4 (templates/secret + 3 final test cases)

**Loop:** 1 | **Run:** gd724xsq

## State on entry

The `templates/secret/` scaffold, the 3 new `test.cyan.yaml` cases (`secret_only`,
`all_features`, `no_llm_all`), and the 3 new snapshot fixtures were already present in
the working tree (uncommitted) from prior session work. This loop was therefore a
verification-and-evidence pass rather than a from-scratch implementation. All artifacts
were validated against the spec's Definition of Done; everything passed without edits.

## Roadblocks / workarounds

- **Docker via OrbStack.** `cyanprint test` needs Docker. This machine uses OrbStack, not
  a daemon at the default socket. Must `export DOCKER_HOST=unix:///Users/erng/.orbstack/run/docker.sock`
  before invoking, and pass the template dir as an **absolute path** (the Bash tool resets
  CWD and zoxide intercepts `cd`, so relative `.` intermittently fails). Recorded in memory.
- **zoxide noise.** Every shell prints a zoxide config warning to stderr; harmless. Set
  `_ZO_DOCTOR=0` to silence.

## Key correctness points verified (decisions/why)

- **AC7 — array concat, not replace.** `secret_only` `Taskfile.yaml` `tasks.setup.cmds`
  resolves to `["echo \"Completed\"", "./scripts/local/secrets.sh"]`. The base command is
  preserved and `secrets.sh` appended. This depends on `atomi/json-yaml`
  `arrayStrategy: concat`; the Ruby validator asserts `size > 1` to catch a silent
  first-write-wins regression.
- **shells.nix arg order is resolver-controlled.** The `atomi/nix` resolver alphabetizes
  named function args, so the regenerated `all_features/nix/shells.nix` first line is
  `{ env, packages, pkgs, shellHook }:` (alphabetical), not the source order. The test uses
  an order-independent check (`tr -d '{}: ' | tr ',' '\n' | sort | paste -sd,`), NOT byte
  equality — byte equality here would be a false failure.
- **C1 lone-colon guard.** Merged nix headers must match `^\{.*\}:$` and never collapse to
  a bare `:` (which happens when `functionArgs` parses empty). `all_features/nix/pre-commit.nix`
  line 1 = `{ formatter, packages, pre-commit-lib }:` — valid. Secret contributes no nix
  (FR6), so `secret_only/nix/` is byte-identical to base's.
- **infisical.md framing (NFR9/AC10).** The `infisical run --env=dev -- <command>`
  subprocess form (with trailing `-- `) is the PRIMARY documented usage (top of the Usage
  section); the bare-form footgun warning is placed below it. Verified the literal string
  `infisical run --env=dev -- ` exists on both source and the generated fixture.
- **secrets.sh uses `infisical run --env=dev -- true`** rather than the spec's illustrative
  bare `infisical run --env=dev`. Both satisfy the functional check (presence of
  `infisical run`); the `-- true` form is a harmless, slightly safer one-shot. No change made.

## Outcome

9/9 cases pass; idempotent on second run; `--update-snapshots` yields no fixture diff
(AC11). All prior fixtures remain green. No code changes were required this loop.
