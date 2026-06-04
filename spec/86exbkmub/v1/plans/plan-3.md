# Plan 3: `templates/helm/` — Helm chart integration scaffold + 2 helm test cases

## Overview

Author the conditionally-emitted Helm scaffold AND the two test cases (`helm_only`,
`docker_helm`) that verify it. Plans 1 and 2 must be merged first so base and docker exist.

The helm folder mirrors helm-shaped conventions in `AtomiCloud/ketone.helm` (VE7) adapted
to this template's `let__var__` syntax and the four resolvers. Like docker, helm's
`ci.yaml`/`cd.yaml`/`Taskfile.yaml`/`nix/*.nix` are partials designed to merge with base
(and now docker) via the resolvers; `infra/root_chart/` files are unique paths and pass
through verbatim.

Critical invariants: `templates/helm/nix/shells.nix` shares the 4-arg signature with
base/docker (VE1); `nix/env.nix` adds `infrautils` to the `system` group, `infralint` to
the `lint` group (VE7) — `helm_only` validates these explicitly.

The `docker_helm` case is the cross-folder merge gate for this plan: it ensures docker's
`docker-build` job AND helm's `helm-lint` job both appear in the merged `ci.yaml`, and
both Taskfile includes (`docker:`, `helm:`) are present after `atomi/json-yaml` merging.

This plan is self-verifying: `cyanprint test template .` exits 0 with 6 cases passing.

## Changes

### `templates/helm/.github/workflows/ci.yaml` (new — partial, FR5)

Single-doc YAML adding `helm-lint` job. `name: CI`, `on:` matching base.

### `templates/helm/.github/workflows/cd.yaml` (new — partial, FR5)

Adds `helm-publish` job.

### `templates/helm/.github/dependabot.yml` (new — partial, FR5)

Helm-related ecosystem entries (or empty `updates:` if helm has no dependabot ecosystem
in this stack — implementation decides).

### `templates/helm/Taskfile.yaml` (new — partial, FR5)

```yaml
version: '3'
includes:
  helm: tasks/Taskfile.helm.yaml
```

### `templates/helm/tasks/Taskfile.helm.yaml` (new — FR5)

Tasks: `helm:lint`, `helm:docs`, `helm:push`. Each shells out to `scripts/ci/helm-*.sh`.

### `templates/helm/scripts/ci/{helm-lint,helm-publish}.sh` (new — FR5)

Each starts with `#!/usr/bin/env bash` and `set -euo pipefail`. Use `infrautils` /
`infralint` from the merged nix env.

### `templates/helm/CLAUDE.md` (new — FR5, VE3)

Single H1: `# Helm`. Links to `docs/developer/standard/helm.md`.

### `templates/helm/.claude/skills/helm-push/SKILL.md` (new — FR5)

Standard skill format.

### `templates/helm/docs/developer/standard/helm.md` (new — FR5)

Docs describing helm chart structure, lint, push. Notes that per-landscape values files
(TD2) are deferred per Out-of-Scope.

### `templates/helm/infra/root_chart/{Chart.yaml,values.yaml,templates/.gitkeep}` (new — FR5)

Minimal helm chart scaffold sufficient for `helm template` to parse:
- `Chart.yaml`: `apiVersion: v2`, `name: let__service__`, `description`,
  `type: application`, `version: 0.1.0`, `appVersion: "1.0.0"`.
- `values.yaml`: `replicaCount: 1` placeholder.
- `templates/.gitkeep`: empty file (or absent if cyanprint preserves empty dirs).

### `templates/helm/nix/env.nix` (new — partial, FR5, VE7)

Adds:
- `infrautils` to the `system` group.
- `infralint` to the `lint` group.
- Optionally `yq` if `helm:docs` requires it (TD3 deferred).

### `templates/helm/nix/pre-commit.nix` (new — partial, FR5)

Adds `a-helm-lint`, `a-helm-docs` hooks.

### `templates/helm/nix/shells.nix` (new — FR5, VE1 critical)

**MUST** use `{ pkgs, packages, env, shellHook }:` (4 args, first line identical to
base/docker).

### Critical resolver constraint: single-line nix function arg declarations

All nix template source files in `templates/helm/nix/` (`shells.nix`, `env.nix`,
`packages.nix`, `pre-commit.nix`, `fmt.nix`) MUST declare function arguments on a
single line. The `atomi/nix` resolver parses `functionArgs` from `lines[0]` only via
balanced-brace matching — multi-line arg lists leave `functionArgs` empty and the
pretty-printer emits a lone `:` on line 1, producing syntactically invalid Nix in every
fixture that consumes the file. Example of REQUIRED form:

```nix
{ packages, formatter, pre-commit-lib }:
```

Example of FORBIDDEN form (breaks the resolver):

```nix
{
  packages,
  formatter,
  pre-commit-lib,
}:
```

This constraint applies to every helm nix source file with a function-arg header.

### `test.cyan.yaml` (extend — FR7 partial: 2 more cases, 6 total)

Add 2 test cases:

- **`helm_only`**: `atomi/{llm,helm}: 'yes'`, `atomi/{docker,secret}: 'no'`. Skill count
  = 9 (7 base + 0 docker + 1 helm + 1 nix-llm? — confirmed = 9 per FR7 table).
  Per-case validators: `grep -q 'helm-lint' .github/workflows/ci.yaml`,
  `grep -q 'helm-publish' .github/workflows/cd.yaml`,
  `test -f .claude/skills/helm-push/SKILL.md`,
  `grep -q '^  helm:' Taskfile.yaml`,
  `grep -q 'infrautils' nix/env.nix`,
  `grep -q 'infralint' nix/env.nix`.

  > Note: FR7 lists `helm_only` skill count as 9. This is base's 7 + helm-push's 1 = 8;
  > the 9th comes from the `atomi/nix` template dependency's optional skill (gated by
  > `cyan/nix/llm`). Since we set `cyan/nix/llm: 'no'`, this discrepancy needs
  > clarification — the spec says count = 9 but our config implies = 8. Implementation
  > note: if test fails, either (a) update fixture and adjust validator to 8, or (b)
  > set `cyan/nix/llm: 'yes'` for LLM-on cases. The spec's `cyan/nix/llm: 'no'` is
  > universal in FR7. **Flagged for resolution during implementation, not blocking
  > planning.**

- **`docker_helm`**: `atomi/{llm,docker,helm}: 'yes'`, `atomi/secret: 'no'`. Skill count
  per FR7 = 9 (same caveat above; should be 7 base + 1 docker + 1 helm = 9).
  Per-case validators: union of docker_only + helm_only (without secret-specific):
  - `grep -q 'docker-build' .github/workflows/ci.yaml`,
  - `grep -q 'helm-lint' .github/workflows/ci.yaml`,
  - `grep -q '^  docker:' Taskfile.yaml`, `grep -q '^  helm:' Taskfile.yaml`,
  - both `docker-push` and `helm-push` skills present.

### `cyan/fixtures/expected/{helm_only,docker_helm}/` (new — FR8 partial: 2 more, 6 total)

Generated via `--update-snapshots`. Each fixture's `nix/shells.nix` first line contains
the same four args (`pkgs`, `packages`, `env`, `shellHook`) — order-independent. The
`atomi/nix` resolver alphabetizes named function arguments deterministically, so the
regenerated fixture first line is `{ env, packages, pkgs, shellHook }:` rather than the
source-level `{ pkgs, packages, env, shellHook }:`. Fixture-level checks must therefore
extract the arg set and verify membership, not byte-equality. `helm_only/nix/env.nix`
contains `infrautils` and `infralint` strings.
`docker_helm/.github/workflows/ci.yaml` contains both `docker-build` and `helm-lint` job
names; `docker_helm/Taskfile.yaml` contains both `docker:` and `helm:` includes.

### Variable substitution audit

Same FR9 discipline. Zero foreign markers.

## Spec Adherence

- **FR5** — Full helm scaffold.
- **FR7** — 2 more test cases (6 of 9).
- **FR8** — 2 more snapshot fixtures (6 of 9).
- **FR9** — `let__var__` discipline.
- **FR10** — CI runner standardization (no new reusable workflows here).
- **FR11** — Cross-folder paths covered by Plan 1's globs.
- **NFR1 Linting** — YAML/shell parse clean.
- **NFR2 Building** — `cyanprint test template .` exits 0 with 6 cases.
- **NFR4 Integration Testing** — 6 cumulative cases.
- **NFR6 Documentation** — Skill + docs.
- **NFR8 Invariant Checking** — 4-arg shells.nix, single-doc YAML.

Acceptance criteria covered:
- **AC5** (full at source level — all three template source `shells.nix` files (base,
  docker, helm) have identical literal first lines `{ pkgs, packages, env, shellHook }:`;
  secret has none per FR6). Fixture-level AC5 is order-independent (the `atomi/nix`
  resolver alphabetizes named args, so regenerated fixtures emit
  `{ env, packages, pkgs, shellHook }:`); fixture validators verify the arg SET, not
  byte-equality.
- **AC6** (partial — 2 more fixtures).
- **AC8** (partial — `docker_helm` covers docker+helm merge correctness for CI/CD/
  Taskfile; full `all_features` is in Plan 4).
- **AC11** (partial — 2 more fixtures stable).

## Acceptance Criteria

### Functional Checks

- `head -n1 templates/helm/nix/shells.nix` outputs `{ pkgs, packages, env, shellHook }:`
  (source-level literal match — the resolver requires single-line args).
- `diff <(head -n1 templates/base/nix/shells.nix) <(head -n1 templates/helm/nix/shells.nix)`
  exits 0 (source-level).
- `diff <(head -n1 templates/docker/nix/shells.nix) <(head -n1 templates/helm/nix/shells.nix)`
  exits 0 (source-level AC5: all three template-source signatures equal).
- For every `.nix` source file under `templates/helm/nix/` that declares function
  arguments, the opening `{ ... }:` MUST appear on a single line (resolver constraint —
  multi-line arg lists corrupt fixture output). Verified by:
  `! grep -lE '^\{[^}]*$' templates/helm/nix/*.nix` (no `.nix` source begins a brace
  block on line 1 without closing it on the same line).
- `find templates/helm -name '*.sh' -exec bash -n {} +` exits 0.
- `find templates/helm -name '*.yaml' -o -name '*.yml' | xargs -I{} ruby -ryaml -e \
  'YAML.safe_load(File.read(ARGV[0]))' {}` exits 0.
- `templates/helm/.github/workflows/{ci,cd}.yaml` each contain `name:`/`on:` keys.
- `templates/helm/CLAUDE.md` has exactly one H1 section.
- `templates/helm/.claude/skills/helm-push/SKILL.md` exists.
- `templates/helm/infra/root_chart/Chart.yaml` parses as YAML and contains
  `apiVersion: v2`, `type: application`.
- `grep -q 'infrautils' templates/helm/nix/env.nix` (VE7).
- `grep -q 'infralint' templates/helm/nix/env.nix` (VE7).
- `! grep -rqE '\{\{|<%=|var__' templates/helm/`.
- `cyanprint test template .` exits 0 with 6 cases passing.
- `cyanprint test template .` (second run) exits 0 — idempotent.
- `cyanprint test template . --update-snapshots && git diff --quiet \
  cyan/fixtures/expected/{helm_only,docker_helm}/` exits 0 — AC11 on new fixtures.
- `helm_only` fixture validators satisfied (see test.cyan.yaml entry above).
- `docker_helm` fixture: `grep -q 'docker-build'` AND `grep -q 'helm-lint'` in merged
  `ci.yaml`; both `docker:` and `helm:` keys in merged `Taskfile.yaml` `includes:`.
- Fixture-level shells.nix arg check (order-independent — replaces literal first-line
  diff on fixtures): for each new fixture (`helm_only`, `docker_helm`) the first line of
  `nix/shells.nix` must contain exactly the four named args `pkgs`, `packages`, `env`,
  `shellHook` in any order. Implementable as:
  `head -n1 cyan/fixtures/expected/<case>/nix/shells.nix | tr -d '{}: ' \
   | tr ',' '\n' | sort | paste -sd, -` equals `env,packages,pkgs,shellHook`.
  Do NOT use literal byte-equality against the source-level signature — the resolver
  alphabetizes args.
- Fixture lone-colon guard (C1 regression): for each new fixture (`helm_only`,
  `docker_helm`), `head -n1 cyan/fixtures/expected/<case>/nix/pre-commit.nix` matches
  `^\{.*\}:$` and is NOT a lone `:`. More generally
  `! grep -rxq ':' cyan/fixtures/expected/{helm_only,docker_helm}/nix/*.nix` — no merged
  nix file has an empty-functionArgs header. (Source-side single-line constraint is already
  enforced above; this adds the missing fixture-side detection.)

### Non-Functional Checks

- All YAML files single-document, plain-object root.
- Plans 1's and 2's existing fixtures still pass cumulatively.
- `nix/shells.nix` cross-folder signature equality re-verified.

## Validation Approach

- **Immediate automated checks**:
  - `cyanprint test template .` (twice) — 6 cases.
  - `cyanprint test template . --update-snapshots && git diff --quiet ...` for 2 new
    fixtures.
  - Per-fixture validators.
  - `diff` chain on shells.nix first lines (base vs docker vs helm).
  - `grep -q 'infrautils|infralint'` on `templates/helm/nix/env.nix`.
- **Post-release checks**: covered in Plan 4.
- **Manual checks**:
  - Read-through of `Chart.yaml` and `values.yaml` for helm chart shape.
  - Verify `templates/helm/nix/env.nix` group naming matches base's group names
    (`system`/`main`/`lint`/`dev`/`releaser`) — typo'd group names cause silent drift.
  - Spot-check of `docker_helm` fixture's merged `ci.yaml` to confirm both jobs in one
    coherent workflow (single `name:`, single `on:`, multiple jobs).
