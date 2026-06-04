# Plan 2: `templates/docker/` — Docker integration scaffold + 2 docker test cases

## Overview

Author the conditionally-emitted Docker scaffold AND the two test cases (`docker_only`,
`no_llm_docker`) that verify it. Plan 1 must be merged first so the orchestrator and base
scaffold exist; this plan adds the docker layer on top.

The docker folder is designed to **merge** with base via the four resolvers, not stand
alone: `ci.yaml`/`cd.yaml`/`Taskfile.yaml`/`dependabot.yml` are partials deep-merged by
`atomi/json-yaml`; `nix/env.nix`/`pre-commit.nix`/`shells.nix` go through `atomi/nix`;
`.dockerignore` and any `.gitignore` additions go through `atomi/ignore`.

The most important invariant: `templates/docker/nix/shells.nix` MUST share the identical
`{ pkgs, packages, env, shellHook }:` signature with base (VE1) — `mergeShells` throws at
generation time on argument-list mismatch, so failures here are caught loudly by either
test case.

This plan is self-verifying: after merge, `cyanprint test template .` exits 0 with 4
cases passing (Plan 1's 2 + this plan's 2).

Additionally, this plan corrects a latent defect in Plan 1's base nix sources:
`templates/base/nix/pre-commit.nix` and `templates/base/nix/packages.nix` ship multi-line
function-arg headers. The `atomi/nix` resolver parses `functionArgs` from `lines[0]` only
(single-line balanced-brace matching), so base contributes an EMPTY arg set and the merged
docker fixture's `pre-commit.nix` collapses to a lone `:` on line 1 — syntactically invalid
Nix. This is invisible in `base_only`/`base_llm` (a single `pre-commit.nix` input passes
through verbatim, multi-line but valid) and fires only when docker adds a second
`pre-commit.nix`, which is exactly this plan's merge. Plan 2 owns the fix because it is the
first merge to expose it.

## Changes

### `templates/docker/.github/workflows/ci.yaml` (new — partial, FR4)

Single-doc YAML with `name: CI`, `on:` matching base. Adds `docker-build` job under
`jobs:`. Uses `runs-on: ubuntu-latest` for non-reusable jobs (or nscloud block if a
`⚡reusable-docker.yaml` is added — implementation decision; current scope is no new
reusable workflow here).

### `templates/docker/.github/workflows/cd.yaml` (new — partial, FR4)

Adds `docker-push` job. Same `name:`/`on:` shape as base.

### `templates/docker/.github/dependabot.yml` (new — partial, FR4)

Adds `package-ecosystem: docker` entry under `updates:`. Merges into base via
`atomi/json-yaml` `arrayStrategy: concat`.

### `templates/docker/Taskfile.yaml` (new — partial, FR4)

```yaml
version: '3'
includes:
  docker: tasks/Taskfile.docker.yaml
```

### `templates/docker/tasks/Taskfile.docker.yaml` (new — FR4)

Standalone taskfile with `version: '3'` and tasks: `docker:build`, `docker:push`,
`docker:lint`. Path is unique (no resolver merge).

### `templates/docker/scripts/ci/{docker-build,docker-push}.sh` (new — FR4)

Each starts with `#!/usr/bin/env bash` and `set -euo pipefail`. Build/push commands
parameterized by `let__platform__` / `let__service__`.

### `templates/docker/.dockerignore` (new — FR4, VE4)

`### ` section headers (`### Build`, `### VCS`, `### Dev`, etc.). Patterns:
`node_modules`, `.git`, `*.log`, etc.

### `templates/docker/CLAUDE.md` (new — FR4, VE3)

Single H1: `# Docker`. Brief paragraph linking to `docs/developer/standard/docker.md`.

### `templates/docker/.claude/skills/docker-push/SKILL.md` (new — FR4)

Standard skill format with frontmatter. References docker conventions.

### `templates/docker/docs/developer/standard/docker.md` (new — FR4)

Docs file. Wording is implementation detail per Out-of-Scope.

### `templates/docker/nix/env.nix` (new — partial, FR4)

Adds docker-only packages (e.g., `skopeo`) to appropriate group. `atomi/nix` does
category-union.

### `templates/docker/nix/pre-commit.nix` (new — partial, FR4)

Adds `a-hadolint` hook. Merges via `atomi/nix` resolver hook deep-merge.

### `templates/docker/nix/shells.nix` (new — FR4, VE1 critical)

**MUST** use `{ pkgs, packages, env, shellHook }:` (4 args, identical first line to
base). Body decided during implementation — minimum: an attrset that `mergeShells`
deep-merges against base.

### `templates/base/nix/{pre-commit,packages}.nix` (correct — single-line headers, prerequisite)

Rewrite both function-arg headers to a single balanced line:
- `templates/base/nix/pre-commit.nix` → `{ packages, formatter, pre-commit-lib }:`
- `templates/base/nix/packages.nix` → `{ pkgs, pkgs-2511, pkgs-unstable, atomi }:`

Bodies unchanged. This makes base contribute a non-empty `functionArgs` set so cross-folder
merges emit a valid `{ … }:` header instead of a lone `:`. `pre-commit.nix` is the actually
broken case today; `packages.nix` currently merges by luck (docker's single-line header
supplies args via union) but is the same latent landmine, so both are corrected for a
uniform single-line invariant.

Consequence: Plan 1's `base_only`/`base_llm` fixtures regenerate (their `nix/pre-commit.nix`
and `nix/packages.nix` first lines change from a bare `{` to the single-line `{ … }:` form).
This is expected, still-valid Nix, and must be re-snapshotted as part of this plan.

### Critical resolver constraint: single-line nix function arg declarations

Every nix source file with a function-arg header — across `templates/base/nix/` AND
`templates/docker/nix/` — MUST declare its arguments on a single line. The `atomi/nix`
resolver reads `functionArgs` from `lines[0]` only via balanced-brace matching; a multi-line
header leaves `functionArgs` empty and the pretty-printer emits a lone `:` on line 1,
producing invalid Nix in every fixture that merges the file. Required form:

```nix
{ packages, formatter, pre-commit-lib }:
```

Forbidden form (breaks the resolver):

```nix
{
  packages,
  formatter,
  pre-commit-lib,
}:
```

### `templates/docker/infra/Dockerfile` (new — FR4, Out-of-Scope clarification)

NOT empty. Minimal multi-stage scaffold (`FROM alpine`, single `COPY`, single `CMD`)
sufficient to pass `docker build`. TD1 (full production Dockerfile) deferred per
Out-of-Scope.

### `test.cyan.yaml` (extend — FR7 partial: 2 more cases, 4 total)

Add 2 test cases:

- **`docker_only`**: `atomi/{llm,docker}: 'yes'`, `atomi/{helm,secret}: 'no'`. Skill
  count = 8 (7 from base + 1 docker-push).
  Per-case validators: `grep -q 'docker-build' .github/workflows/ci.yaml`,
  `test -f .claude/skills/docker-push/SKILL.md`, `grep -q '^  docker:' Taskfile.yaml`
  (under `includes:`).
- **`no_llm_docker`**: `atomi/llm: 'no'`, `atomi/docker: 'yes'`, `atomi/{helm,secret}: 'no'`.
  Skill count = 0.
  Per-case validators: `test ! -f CLAUDE.md`, `test ! -d .claude` (LLM-off discipline,
  even when docker is enabled), but `grep -q 'docker-build' .github/workflows/ci.yaml`
  (docker artifacts still present).

Both cases share the universal validators (shell parse, YAML parse, no `let__`, no
`flake.nix`).

### `cyan/fixtures/expected/{docker_only,no_llm_docker}/` (new — FR8 partial: 2 more, 4 total)

Generated via `--update-snapshots`. Each fixture's `nix/shells.nix` first line contains
the same four named args as base (`pkgs`, `packages`, `env`, `shellHook`),
order-independent — the `atomi/nix` resolver alphabetizes named function arguments by
design, so the regenerated fixture's first line will be
`{ env, packages, pkgs, shellHook }:`, not the source-level
`{ pkgs, packages, env, shellHook }:`. Each fixture's `ci.yaml` and `cd.yaml` are merged
base+docker outputs.

### Variable substitution audit

Same FR9 discipline as Plan 1. Zero foreign markers in `templates/docker/`.

## Spec Adherence

- **FR4** — Full docker scaffold (every file listed).
- **FR7** — Test cases (2 more: `docker_only`, `no_llm_docker`; 4 of 9 cumulative).
- **FR8** — Snapshot fixtures (2 more; 4 of 9 cumulative).
- **FR9** — `let__var__` discipline.
- **FR10** — CI runner standardization (no new reusable workflows here unless added).
- **FR11** — Cross-folder paths covered by Plan 1's resolver glob list (verified: every
  partial path in this plan is in the glob list).
- **NFR1 Linting** — YAML/shell parse clean.
- **NFR2 Building** — `cyanprint test template .` exits 0 with 4 cases.
- **NFR4 Integration Testing** — 4 cumulative cases.
- **NFR6 Documentation** — Skill + docs file.
- **NFR8 Invariant Checking** — 4-arg shells.nix (cross-folder equality with base),
  `### ` in `.dockerignore`, `name:`/`on:` preserved in workflow partials, single-doc YAML.

Acceptance criteria covered or partly covered:
- **AC5** (partial — docker shells.nix) — source-level literal equality with base
  verified via
  `diff <(head -n1 templates/base/nix/shells.nix) <(head -n1 templates/docker/nix/shells.nix)`.
  Fixture-level AC5 is order-independent (resolver alphabetizes args).
- **AC6** (partial — `docker_only` and `no_llm_docker` fixtures) — universal validators.
- **AC9** (partial — `no_llm_docker` is the docker-feature LLM-off case): `test ! -f
  CLAUDE.md`, `test ! -d .claude`, but docker artifacts present.
- **AC11** (partial — on these 2 new fixtures): regenerate-and-diff is empty.

## Acceptance Criteria

### Functional Checks

- `head -n1 templates/docker/nix/shells.nix` outputs exactly
  `{ pkgs, packages, env, shellHook }:` (AC5).
- `head -n1 templates/base/nix/pre-commit.nix` matches `^\{.*\}:$` (single-line, balanced —
  corrected from Plan 1's multi-line header).
- `head -n1 templates/base/nix/packages.nix` matches `^\{.*\}:$` (single-line, balanced).
- `head -n1 cyan/fixtures/expected/docker_only/nix/pre-commit.nix` matches `^\{.*\}:$` and
  is NOT a lone `:` (the C1 regression guard — this is the exact line that was broken).
- `head -n1 cyan/fixtures/expected/no_llm_docker/nix/pre-commit.nix` matches `^\{.*\}:$`
  and is NOT a lone `:`.
- `! grep -rxq ':' cyan/fixtures/expected/*/nix/*.nix` — no merged nix fixture has a
  lone-colon (empty-functionArgs) header line anywhere.
- `diff <(head -n1 templates/base/nix/shells.nix) <(head -n1 templates/docker/nix/shells.nix)`
  exits 0 (signature equality).
- `find templates/docker -name '*.sh' -exec bash -n {} +` exits 0.
- `find templates/docker -name '*.yaml' -o -name '*.yml' | xargs -I{} ruby -ryaml -e \
  'YAML.safe_load(File.read(ARGV[0]))' {}` exits 0.
- `templates/docker/.github/workflows/{ci,cd}.yaml` each contain `name:` and `on:` keys.
- `templates/docker/.dockerignore` contains at least one `### ` section header.
- `templates/docker/CLAUDE.md` has exactly one H1 section.
- `templates/docker/.claude/skills/docker-push/SKILL.md` exists.
- `templates/docker/infra/Dockerfile` has non-zero size and contains `FROM`.
- `! grep -rqE '\{\{|<%=|var__' templates/docker/`.
- `cyanprint test template .` exits 0 with 4 cases passing (Plan 1's 2 + this plan's 2).
- `cyanprint test template .` (second invocation) exits 0 — idempotent.
- `cyanprint test template . --update-snapshots && git diff --quiet \
  cyan/fixtures/expected/{docker_only,no_llm_docker}/` exits 0 — AC11 on new fixtures.
- For each new fixture: `! grep -rqE 'let__[a-zA-Z_]+__'`, `test ! -f flake.nix`,
  shell `bash -n`, YAML `ruby -ryaml` (AC6 partial).
- `docker_only` fixture: `grep -q 'docker-build' \
  cyan/fixtures/expected/docker_only/.github/workflows/ci.yaml`,
  `[ "$(find cyan/fixtures/expected/docker_only/.claude/skills -name SKILL.md | wc -l)" = "8" ]`.
- `no_llm_docker` fixture: `test ! -f cyan/fixtures/expected/no_llm_docker/CLAUDE.md`,
  `test ! -d cyan/fixtures/expected/no_llm_docker/.claude`,
  `grep -q 'docker-build' cyan/fixtures/expected/no_llm_docker/.github/workflows/ci.yaml`.

### Non-Functional Checks

- All `.sh` files have shebang + `set -euo pipefail` (NFR8).
- All YAML single-document, plain-object root.
- `nix/shells.nix` first-line equality with base verified.
- Plan 1's `base_only` and `base_llm` fixtures regenerate as part of this plan (their
  `nix/pre-commit.nix` and `nix/packages.nix` first lines change to the single-line
  `{ … }:` form) and must remain green — the cumulative suite stays passing, not just
  the per-plan cases.

## Validation Approach

- **Immediate automated checks**:
  - `cyanprint test template .` (twice) — 4 cases.
  - `cyanprint test template . --update-snapshots && git diff --quiet ...` for the 2
    new fixtures.
  - Per-fixture validators (find/grep/bash -n/ruby -ryaml).
  - `diff` on shells.nix first line.
- **Post-release checks**: covered in Plan 4 (`cyan run` smoke on `all_features` will
  exercise docker artifacts in a generated project).
- **Manual checks**:
  - Read-through of `templates/docker/.github/workflows/ci.yaml` to confirm partial
    YAML shape (matching `name:`/`on:` with base, isolated `jobs:` additions).
  - Read-through of `Dockerfile` to confirm minimal multi-stage scaffold (not empty).
  - Spot-check of `docker_only/Taskfile.yaml` to confirm `docker:` key under
    `includes:` (`atomi/json-yaml` deep-merge worked).
