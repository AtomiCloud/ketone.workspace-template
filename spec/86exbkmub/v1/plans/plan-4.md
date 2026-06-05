# Plan 4: `templates/secret/` — Infisical scaffold + 3 final test cases (full spec coverage)

## Overview

Author the conditionally-emitted Secret scaffold AND the final three test cases
(`secret_only`, `all_features`, `no_llm_all`) that complete the spec's verification
matrix. Plans 1–3 must be merged first.

The smallest of the four folders. It contributes a setup script
(`scripts/local/secrets.sh`), a Taskfile partial, a `.gitignore` `### Secrets` section,
an Infisical CLAUDE.md H1 section, an Infisical skill, and the `infisical.md` developer
doc. Critically, this folder contributes **no nix files** — FR6 final paragraph is
explicit (the `infisical` CLI is already in base's env via `a-infisical` /
`a-infisical-staged` pre-commit hooks).

Critical asymmetry from other folders: `infisical.md` MUST show the subprocess form
`infisical run --env=dev -- <command>` (with trailing `-- `) per VE11 and AC10. Bare
`infisical run --env=dev` (no `-- <command>`) does not propagate secrets to the parent
shell — a footgun this doc must explicitly call out.

Also notable: secret's `Taskfile.yaml` `tasks.setup.cmds:` array, when merged with base's
via `arrayStrategy: concat`, **appends** `./scripts/local/secrets.sh` to base's existing
setup commands rather than replacing them. AC7 is the explicit guard against
"first-write-wins" silent failures here.

This plan completes the integration suite: 9 cases, full spec coverage. It is the
acceptance gate for AC1, AC7, AC8, AC9 (full), AC10, AC11 (full).

## Changes

### `templates/secret/scripts/local/secrets.sh` (new — FR6)

```bash
#!/usr/bin/env bash
set -euo pipefail
INFISICAL_API_URL="https://secrets.atomi.cloud" infisical login
infisical run --env=dev
```

The bare `infisical run --env=dev` (no `--`) is acceptable here per VE11: this is a
one-shot fetch following an interactive `login`, not a documented user-facing pattern.

### `templates/secret/Taskfile.yaml` (new — partial, FR6)

```yaml
version: '3'
includes:
  secret: tasks/Taskfile.secret.yaml
tasks:
  setup:
    cmds:
      - ./scripts/local/secrets.sh
```

When merged with base via `atomi/json-yaml` `arrayStrategy: concat`, `setup.cmds` becomes
`[<base's setup commands…>, ./scripts/local/secrets.sh]`. AC7 explicitly asserts this.

### `templates/secret/tasks/Taskfile.secret.yaml` (new — FR6)

`version: '3'`, tasks: `secret:fetch`, `secret:scan`. Path is unique.

### `templates/secret/.gitignore` (new — FR6, VE4)

```
### Secrets
.env
.env.*
*.tfvars
.infisical.json
```

`atomi/ignore` merges this with base's sections.

### `templates/secret/docs/developer/standard/infisical.md` (new — FR6, VE11, AC10)

Documents Infisical at `https://secrets.atomi.cloud`. Required content:
- Literal string `infisical run --env=dev -- ` (with trailing `-- `) — AC10.
- Concrete examples: `infisical run --env=dev -- env | grep MY_SECRET`,
  `infisical run --env=dev -- pls test`.
- Explicit warning that bare `infisical run --env=dev` does NOT propagate secrets to the
  parent shell (footgun per NFR9).
- Link back to `scripts/local/secrets.sh`.

### `templates/secret/CLAUDE.md` (new — FR6, VE3)

```markdown
# Secret Management

This project uses Infisical for secret management. Use `pls setup` to authenticate
and fetch secrets. See [docs/developer/standard/infisical.md](docs/developer/standard/infisical.md)
for details.
```

### `templates/secret/.claude/skills/infisical/SKILL.md` (new — FR6)

Standard skill format. References docs. Mirrors AC10's `-- <command>` emphasis.

### No nix files (FR6 invariant)

`templates/secret/nix/` does NOT exist. Verified in functional checks.

### Forward-compatibility note: single-line nix function arg constraint

If FR6 is ever extended to allow nix files in `templates/secret/`, those files MUST
declare function arguments on a single line. The `atomi/nix` resolver parses
`functionArgs` from `lines[0]` only (balanced-brace matching) — multi-line arg lists
leave `functionArgs` empty and emit a lone `:` on line 1, producing syntactically
invalid Nix. This constraint is the same one Plan 3 documents for helm and Plan 1/2
already follow for base/docker; it is recorded here preventively.

### `test.cyan.yaml` (extend — FR7 partial: 3 more cases, 9 total)

Add 3 final test cases:

- **`secret_only`**: `atomi/{llm,secret}: 'yes'`, `atomi/{docker,helm}: 'no'`. Skill
  count = 8 (7 base + 1 infisical).
  Per-case validators:
  - `test -f scripts/local/secrets.sh`,
  - `grep -q '^### Secrets' .gitignore`,
  - `test -f .claude/skills/infisical/SKILL.md`,
  - `grep -F 'infisical run --env=dev -- ' docs/developer/standard/infisical.md` (AC10),
  - `ruby -ryaml -e 'doc=YAML.safe_load(File.read("Taskfile.yaml")); cmds=doc["tasks"]["setup"]["cmds"]; \
     exit(cmds.is_a?(Array) && cmds.include?("./scripts/local/secrets.sh") && cmds.size > 1 ? 0 : 1)'`
    (AC7: secrets.sh appended, NOT replacing base's commands).

- **`all_features`**: all four feature flags `'yes'`. Skill count = 10
  (7 base + 1 docker + 1 helm + 1 infisical).
  Per-case validators (AC8):
  - `Taskfile.yaml` has `docker:`, `helm:`, `secret:` keys under `includes:`.
  - `.github/workflows/ci.yaml` has `docker-build` AND `helm-lint`.
  - `.github/workflows/cd.yaml` has `docker-push` AND `helm-publish`.
  - `.gitignore` contains `### ` sections from base AND `### Secrets`.
  - `CLAUDE.md` contains H1 sections from all four folders.
  - `[ "$(find .claude/skills -name SKILL.md | wc -l)" = "10" ]`.
  - `head -n1 nix/shells.nix` first line contains exactly the four named args `pkgs`,
    `packages`, `env`, `shellHook` (order-independent — the `atomi/nix` resolver
    alphabetizes named args, so the literal regenerated first line is
    `{ env, packages, pkgs, shellHook }:`, not the source-level
    `{ pkgs, packages, env, shellHook }:`).

- **`no_llm_all`**: `atomi/llm: 'no'`, all three feature flags `'yes'`. Skill count = 0.
  Per-case validators (AC9):
  - `test ! -f CLAUDE.md`, `test ! -d .claude` (LLM-off discipline).
  - All feature artifacts present: docker-build job in CI, helm Chart.yaml,
    secrets.sh script, `### Secrets` in `.gitignore`.

### `cyan/fixtures/expected/{secret_only,all_features,no_llm_all}/` (new — FR8 partial: 3 more, 9 total)

Generated via `--update-snapshots`. Each fixture's `nix/shells.nix` first line contains
the same four named args as base (`pkgs`, `packages`, `env`, `shellHook`),
order-independent — the `atomi/nix` resolver alphabetizes named function arguments by
design, so the regenerated fixture's first line is `{ env, packages, pkgs, shellHook }:`
rather than the source-level `{ pkgs, packages, env, shellHook }:`. `secret_only` shares
base's nix verbatim (secret contributes no nix files per FR6).
`secret_only/Taskfile.yaml` `tasks.setup.cmds` is a list with multiple entries
(AC7). `all_features/.gitignore` contains `### Secrets` section AND base's sections
(AC8). `no_llm_all/` contains all feature directories EXCEPT `.claude/` and no
`CLAUDE.md` (AC9).

### Variable substitution audit

Same FR9 discipline. Note: there are no `let__platform__`/`let__service__` substitutions
needed inside `templates/secret/` (secrets management is workspace-generic, not
service-specific).

## Spec Adherence

- **FR6** — Full secret scaffold (every file listed; explicit no-nix constraint observed).
- **FR7** — 3 final test cases (9 of 9 cumulative; full spec coverage).
- **FR8** — 3 final snapshot fixtures (9 of 9).
- **FR9** — `let__var__` discipline.
- **FR11** — Cross-folder paths (`Taskfile.yaml`, `.gitignore`, `CLAUDE.md`) covered by
  Plan 1's globs.
- **NFR1 Linting** — YAML/shell parse clean.
- **NFR2 Building** — `cyanprint test template .` exits 0 with all 9 cases (AC1 full).
- **NFR4 Integration Testing** — 9 cumulative cases — full spec coverage.
- **NFR6 Documentation** — `infisical.md` (with AC10 contract), CLAUDE.md, skill.
- **NFR8 Invariant Checking** — `### Secrets` in `.gitignore`, `# ` H1 in CLAUDE.md,
  single-doc YAML, AC7 cmds-array concat. Fixture-level shells.nix arg check is
  order-independent (resolver alphabetizes named args); source-level shells.nix
  literal first-line equality remains enforced (no nix sources in secret per FR6, but
  prior plans' source-level checks remain green).
- **NFR9 Security** — `infisical.md` calls out the bare-form footgun.

Acceptance criteria covered:
- **AC1** (full) — `cyanprint test template .` exits 0 with all 9 cases. Run twice
  for idempotency.
- **AC6** (full) — all 9 fixtures pass per-fixture validators (no `let__`, no
  `flake.nix`, shell parse, YAML parse). Plans 1–3's existing fixtures still pass.
- **AC7** (full) — `secret_only` Taskfile concat correctness explicitly tested.
- **AC8** (full) — `all_features` merge correctness explicitly tested.
- **AC9** (full) — `no_llm_all` (and `base_only`, `no_llm_docker` from prior plans)
  cover LLM gating discipline.
- **AC10** (full) — `infisical.md` `-- ` subprocess form on `secret_only` fixture.
- **AC11** (full) — re-running `--update-snapshots` produces no diff across all 9
  fixtures.

## Acceptance Criteria

### Functional Checks

- `templates/secret/scripts/local/secrets.sh` exists, has `#!/usr/bin/env bash` and
  `set -euo pipefail`, and contains both `infisical login` and `infisical run`.
- `bash -n templates/secret/scripts/local/secrets.sh` exits 0.
- `templates/secret/Taskfile.yaml` parses as single-doc YAML; `tasks.setup.cmds` contains
  `./scripts/local/secrets.sh`.
- `templates/secret/.gitignore` contains `### Secrets` section header (literal).
- `grep -F 'infisical run --env=dev -- ' \
  templates/secret/docs/developer/standard/infisical.md` exits 0 (AC10 source-side).
- `templates/secret/CLAUDE.md` contains exactly one H1 section starting with
  `# Secret Management`.
- `templates/secret/.claude/skills/infisical/SKILL.md` exists.
- `! test -d templates/secret/nix` — FR6 invariant.
- `! grep -rqE '\{\{|<%=|var__' templates/secret/`.
- `cyanprint test template .` exits 0 with **9 cases passing** (AC1 full).
- `cyanprint test template .` (second invocation) exits 0 — idempotent (AC1 full).
- `cyanprint test template . --update-snapshots && git diff --quiet \
  cyan/fixtures/expected/` exits 0 — AC11 across all 9 fixtures.
- `secret_only` fixture (AC7): `tasks.setup.cmds` array contains BOTH base's existing
  setup commands AND `./scripts/local/secrets.sh`. The array length > 1.
- `all_features` fixture (AC8 — every clause):
  - `grep -q '^  docker:' Taskfile.yaml`, `grep -q '^  helm:' Taskfile.yaml`,
    `grep -q '^  secret:' Taskfile.yaml`.
  - `grep -E '(precommit|docker-build|helm-lint)' .github/workflows/ci.yaml` matches all
    three.
  - `grep -E '(docker-push|helm-publish)' .github/workflows/cd.yaml` matches both.
  - `grep -q '^### Secrets' .gitignore` AND `grep -cq '^### ' .gitignore` ≥ 6 (5+ from
    base, +1 from secret).
  - `[ "$(find .claude/skills -name SKILL.md | wc -l)" = "10" ]`.
  - Fixture-level shells.nix arg check (order-independent): the first line of
    `nix/shells.nix` contains exactly the four named args `pkgs`, `packages`, `env`,
    `shellHook` in any order. Implementable as
    `head -n1 cyan/fixtures/expected/all_features/nix/shells.nix | tr -d '{}: ' \
    | tr ',' '\n' | sort | paste -sd, -` equals `env,packages,pkgs,shellHook`. Do NOT
    use literal byte-equality — the resolver alphabetizes named args.
  - `grep -E '^# (Docker|Helm|Secret Management)' CLAUDE.md` matches all three.
- `no_llm_all` fixture (AC9): `test ! -f CLAUDE.md`, `test ! -d .claude`,
  `test -f scripts/local/secrets.sh`, `grep -q 'docker-build' .github/workflows/ci.yaml`,
  `test -f infra/root_chart/Chart.yaml`.
- `secret_only` fixture (AC10): `grep -F 'infisical run --env=dev -- ' \
  docs/developer/standard/infisical.md` exits 0.
- Fixture lone-colon guard (C1 regression): for each new fixture (`secret_only`,
  `all_features`, `no_llm_all`) every `nix/*.nix` header is valid —
  `! grep -rxq ':' cyan/fixtures/expected/{secret_only,all_features,no_llm_all}/nix/*.nix`
  (no merged nix file collapses to an empty-functionArgs `:` line). `secret_only` shares
  base's nix verbatim (secret contributes no nix per FR6); `all_features` merges
  base+docker+helm nix and its `nix/pre-commit.nix` first line must match `^\{.*\}:$`,
  never a lone `:`.

### Non-Functional Checks

- `### Secrets` section header is exactly three hashes + single space + content (`atomi/ignore`).
- `# Secret Management` H1 is exactly one hash + single space + content (`atomi/md`).
- All YAML in `templates/secret/` and the 3 new fixtures is single-document.
- All prior fixtures (`base_only`, `base_llm`, `docker_only`, `no_llm_docker`,
  `helm_only`, `docker_helm`) still pass after this plan — cumulative test suite stays
  green.
- `infisical.md` framing: the `-- <command>` form is the PRIMARY documented usage (not
  buried below the bare form).

## Validation Approach

- **Immediate automated checks**:
  - `cyanprint test template .` (twice) — 9 cases (AC1 full).
  - `cyanprint test template . --update-snapshots && git diff --quiet \
    cyan/fixtures/expected/` — AC11 full.
  - All 9 per-fixture validators (AC6 full).
  - AC7, AC8, AC9, AC10 explicit checks.
  - `grep -F 'infisical run --env=dev -- '` on both source and fixture.
- **Post-release manual checks** (per triage validation matrix; not blocking merge):
  - Run `cyan run` against the published template once for `base_only` and once for
    `all_features`, then `pls setup` / `direnv allow` / `pls helm:*` /
    `infisical run --env=dev -- env` in the generated project. This catches runtime
    issues snapshot tests cannot (TD1/TD2/TD3 footguns).
  - These are post-release because the published-template URL is gated on PR merge;
    they are not part of this plan's automated gate.
- **Manual immediate checks**:
  - One-time eyeball of `all_features/CLAUDE.md`, `.gitignore`, `ci.yaml`, and
    `shells.nix` to confirm semantic correctness, not just byte-equality to a
    just-regenerated snapshot.
  - Spot-check of `secret_only/Taskfile.yaml` `tasks.setup.cmds` to confirm
    `./scripts/local/secrets.sh` is **appended** to base's existing commands
    (AC7 — easy to silently fail under the wrong `arrayStrategy`).
  - Read-through of `infisical.md` to confirm `-- <command>` framing is the primary
    pattern.
