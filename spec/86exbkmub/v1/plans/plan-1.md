# Plan 1: Foundation — entry point, `cyan.yaml`, base scaffold, and 2 base test cases

## Overview

Establish the architectural backbone AND the always-emitted base scaffold in one
self-verifying unit. This plan delivers the minimum end-to-end runnable template: the
TypeScript orchestrator (`cyan/index.ts` + `cyan/src/standard.ts`), the orchestrator
manifest (`cyan.yaml` with all four resolvers and the `atomi/nix` template dependency),
the full `templates/base/` scaffold (~30 files), and the first two snapshot test cases
(`base_only`, `base_llm`) with their fixtures.

Foundation and base are bundled because foundation alone has no end-to-end verification
path: `cyanprint test template .` requires `templates/base/` to exist (the unconditional
processor in the orchestrator references it). Bundling produces a natural unit — the
"always-on layer" of the template — that compiles, runs, and verifies as a single commit.

This plan addresses the highest-risk authoring decision (VE6: 4-arg `shells.nix` from the
start) and locks in the contracts (`varSyntax`, processor push order, resolver glob list)
that Plans 2–4 must conform to.

## Changes

### `cyan/index.ts` (rewrite — FR1)

Implement `StartTemplateWithLambda`:
- Call `await standardPrompts(i)` and destructure `{ platform, service, llm, docker, helm, secret }`.
- Declare `const varSyntax: [string, string][] = [['let__','__'], ['// let__','__'], ['# let__','__']]`.
- Build `const exclude = llm === false ? ['**/CLAUDE.md', '**/.claude/**/*', '**/.claude/**/*.*'] : []`.
- Push a `cyan/default` processor for `templates/base` (unconditional) with `GlobType.Template`
  and `exclude`.
- Conditionally push the same processor shape for `templates/docker`, `templates/helm`,
  `templates/secret` when their respective answers are truthy. Push order is canonical:
  base → docker → helm → secret (Domain NFR Determinism).
- Return `{ processors, plugins: [] }`.

The conditional pushes for docker/helm/secret are scaffolded NOW even though those
folders ship in Plans 2–4. This is intentional: if a user answers `atomi/docker: yes`
during Plan 1's tests, the orchestrator looks for `templates/docker/` and fails. The Plan 1
test cases (`base_only`, `base_llm`) both answer `no` to docker/helm/secret, so the
conditional pushes are dead code at this plan's verification time but exist in the
contract.

### `cyan/src/standard.ts` (new — FR1)

Six prompts in this exact order:
1. `i.text('Platform', 'atomi/platform', 'LPSM Service Tree Platform')` → `.toLowerCase()`.
2. `i.text('Service', 'atomi/service', 'LPSM Service Tree Service')` → `.toLowerCase()`.
3. `i.confirm('Enable LLM Support', 'atomi/llm', 'Add CLAUDE.md and Claude skills')`.
4. `i.confirm('Enable Docker', 'atomi/docker', 'Enable Docker Integration')`.
5. `i.confirm('Enable Helm', 'atomi/helm', 'Enable Helm Chart Integration')`.
6. `i.confirm('Enable Secret Management', 'atomi/secret', 'Enable Secret Management')`.

Signature:
```ts
export async function standardPrompts(i: IInquirer): Promise<{
  platform: string; service: string;
  llm: boolean; docker: boolean; helm: boolean; secret: boolean;
}>
```

### `cyan.yaml` (rewrite — FR2, FR11)

- `templates: [{ template: atomi/nix, answers: { cyan/nix/basic: 'yes', cyan/nix/llm: 'no' } }]`.
- `processors: [cyan/default]`, `plugins: []`.
- `resolvers:` exactly four entries:
  - `atomi/json-yaml`, `config: { arrayStrategy: concat }`,
    files: `.github/workflows/{ci,cd,release}.yaml`, `.github/dependabot.yml`,
    `Taskfile.yaml`, `.coderabbit.yaml`, `atomi_release.yaml`.
  - `atomi/md`, `config: {}`, files: `CLAUDE.md`, `README.md`, `.envrc`.
  - `atomi/ignore`, `config: {}`, files: `.gitignore`, `.dockerignore`.
  - `atomi/nix`, `config: {}`, files: `nix/{packages,env,shells,fmt,pre-commit}.nix`.
- `commands: ['chmod +x scripts/ci/*.sh 2>/dev/null || true']`.
- `build:` block matching registry shape.

### `templates/base/nix/shells.nix` (new — FR3, VE6 critical)

First line MUST be exactly `{ pkgs, packages, env, shellHook }:` (4 args). The string
`preCommitPackages` MUST NOT appear anywhere. `buildInputs` lists:
- `default`: `system ++ main ++ lint ++ dev`
- `ci`: `system ++ main ++ lint`
- `releaser`: `system ++ main ++ lint ++ releaser`

### `templates/base/nix/{env,packages,fmt,pre-commit}.nix` (new — FR3)

Mirror `86ex0pvna` shapes with corrections. `env.nix` lint group keeps
`pre-commit, treefmt, gitlint, shellcheck, sg, actionlint, go-task` (these provide what
`preCommitPackages` previously did).

### `templates/base/.github/` (new — FR3, FR10)

- `workflows/ci.yaml`, `cd.yaml`, `release.yaml` — single-doc YAMLs with `name:`/`on:`
  preserved (so Plans 2/3 can deep-merge into them).
- `workflows/⚡reusable-precommit.yaml`, `⚡reusable-release.yaml` — MUST use
  `runs-on: [nscloud-ubuntu-22.04-amd64-32x64-with-cache, nscloud-cache-size-50gb,
   nscloud-cache-tag-atomi-nix-store-cache]` (FR10).
- `workflows/🛡️merge-gatekeeper.yml` — may use `ubuntu-latest`.
- `actionlint.yaml`, `dependabot.yml` — standard scaffolds.

### `templates/base/Taskfile.yaml` (new — FR3)

`version: '3'`, base tasks (`setup`, `lint`, `test`, `build`, `clean`). `setup.cmds` is a
LIST (not a string) so secret folder can `arrayStrategy: concat` append in Plan 4.

### `templates/base/.gitignore` (new — FR3, VE4)

`### ` section headers: `### macOS`, `### Windows`, `### Linux`, `### IDE`, `### Project`,
`### Nix`. Patterns within each section are deduplicable.

### `templates/base/CLAUDE.md` (new — FR3, VE3)

Seven H1 sections, one per topic: `# CI/CD`, `# Conventional Commits`, `# Linting`,
`# Semantic Release`, `# Service Tree`, `# Shell Conventions`, `# Taskfile Conventions`.
Each links to the corresponding `docs/developer/standard/*.md`.

### `templates/base/.claude/skills/{ci-cd-workflows,conventional-commits,linting,semantic-release,service-tree,shell-conventions,taskfile-conventions}/SKILL.md` (new — 7 skills, FR3)

Standard Claude skill format with frontmatter.

### `templates/base/docs/developer/{CommitConventions.md, standard/{ci-cd,conventional-commits,linting,semantic-release,service-tree,shell-scripts,taskfile}.md}` (new)

Core developer docs. Wording is implementation detail per Out-of-Scope.

### `templates/base/scripts/ci/{pre-commit,release,setup}.sh` (new — FR3)

Each starts with `#!/usr/bin/env bash` and `set -euo pipefail`. `chmod +x` handled by
`cyan.yaml` `commands:` block.

### `templates/base/{.envrc,.gitlint,.prettierrc.yaml,.coderabbit.yaml,atomi_release.yaml}` (new — FR3)

Standard config files.

### `test.cyan.yaml` (rewrite — FR7 partial: 2 of 9 cases)

Replace any placeholder. Add 2 test cases:

- **`base_only`**: `atomi/{platform,service}: 'test-platform'/'test-service'`,
  `atomi/{llm,docker,helm,secret}: 'no'`, `cyan/nix/basic: 'yes'`, `cyan/nix/llm: 'no'`.
  Validators: universal (shell parse, YAML parse, no `let__`, no `flake.nix`) +
  `test ! -f CLAUDE.md`, `test ! -d .claude`.
- **`base_llm`**: same but `atomi/llm: 'yes'`.
  Validators: universal + `[ "$(find .claude/skills -name SKILL.md | wc -l)" = "7" ]`.

Both cases use `expected.type: snapshot`,
`expected.value.path: cyan/fixtures/expected/<case>`, and `deterministic_state: {}`.

### `cyan/fixtures/expected/{base_only,base_llm}/` (new — FR8 partial: 2 of 9 fixtures)

Generated via `cyanprint test template . --update-snapshots`. Committed to repo.
Each contains exactly the files this template's base layer produces for that case.
No `flake.nix`, no `let__` markers anywhere.

### Variable substitution audit

All `let__platform__` / `let__service__` references are bare in markdown/yaml/text, with
`// let__...__` in TS/JS/C# and `# let__...__` in shell/python/nix comments (FR9). Zero
`{{ }}`, `<%= %>`, or `var__...__` markers anywhere in `templates/base/`.

## Spec Adherence

- **FR1** — Template entry point with composable additive processors (full).
- **FR2** — `cyan.yaml` declaring all four resolvers and `atomi/nix` template dependency
  (full).
- **FR3** — `templates/base/` scaffold (full).
- **FR7** — Test cases (2 of 9: `base_only`, `base_llm`).
- **FR8** — Snapshot fixtures (2 of 9).
- **FR9** — Variable syntax discipline (declared in `cyan/index.ts`; enforced in base).
- **FR10** — CI runner standardization (base reusable workflows).
- **FR11** — Resolver file globs cover every cross-folder file (declared canonical list).
- **NFR1 Linting** — All YAML/shell files lint clean.
- **NFR2 Building** — `cd cyan && npx tsc --noEmit` exits 0; `cyanprint test template .`
  exits 0 (with 2 cases).
- **NFR4 Integration Testing** — 2 cases passing constitutes the partial integration
  suite for this plan.
- **NFR6 Documentation** — Skills + standard/*.md docs.
- **NFR8 Invariant Checking** — All AC5 invariants enforced at this plan
  (4-arg shells.nix, no `preCommitPackages`, `### ` in `.gitignore`, `# ` H1 in CLAUDE.md,
  shell shebang + `set -euo pipefail`, no `let__` markers in fixtures, no `flake.nix`).
- **NFR11 Backwards Compatibility** — Breaking change (new prompt IDs / order) accepted.

Acceptance criteria covered or partly covered:
- **AC2** (full) — `tsc --noEmit` exits 0.
- **AC3** (full) — `cyan/index.ts` and `cyan/src/standard.ts` present, prompt sequence
  matches spec exactly.
- **AC4** (full) — `cyan.yaml` includes the `atomi/nix` template entry and 4 resolvers.
- **AC5** (partial — base shells.nix) — first line is `{ pkgs, packages, env, shellHook }:`,
  no `preCommitPackages`. Equality across all four shells.nix files confirmed in Plans 2–4.
- **AC6** (partial — base_only and base_llm fixtures) — no `let__`, no `flake.nix`,
  shell parse, YAML parse on those two fixtures.
- **AC9** (partial — base_only is the simplest LLM-off case): `test ! -f CLAUDE.md` and
  `test ! -d .claude`. Multi-feature LLM-off cases verified in Plans 2 and 4.
- **AC11** (partial — on these 2 fixtures): re-running `--update-snapshots` produces no
  diff under the 2 fixtures.

## Acceptance Criteria

### Functional Checks

- `cd cyan && npx tsc --noEmit` exits 0.
- `ruby -ryaml -e 'YAML.safe_load(STDIN)' < cyan.yaml` exits 0.
- `grep -c '^- resolver:' cyan.yaml` ≥ 4 (AC4).
- `head -n1 templates/base/nix/shells.nix` outputs exactly
  `{ pkgs, packages, env, shellHook }:` (AC5 partial).
- `! grep -q 'preCommitPackages' templates/base/nix/shells.nix`.
- `find templates/base/.claude/skills -name SKILL.md | wc -l` = 7.
- `templates/base/CLAUDE.md` has exactly 7 H1 sections (`grep -c '^# ' = 7`).
- `templates/base/.gitignore` contains at least one `### ` section header.
- All `templates/base/.github/workflows/⚡reusable-*.yaml` files contain the three
  `nscloud-*` runs-on entries (FR10).
- `cyanprint test template .` exits 0 with 2 cases passing.
- `cyanprint test template .` (second invocation, no flag) exits 0 — idempotent.
- `cyanprint test template . --update-snapshots && git diff --quiet \
  cyan/fixtures/expected/` exits 0 — AC11 stability on the 2 fixtures.
- For both fixtures: `! grep -rqE 'let__[a-zA-Z_]+__' cyan/fixtures/expected/<case>/`,
  `test ! -f cyan/fixtures/expected/<case>/flake.nix`,
  `find cyan/fixtures/expected/<case> -name '*.sh' -exec bash -n {} +` exits 0,
  every YAML in the fixture parses with `ruby -ryaml`.
- `base_only` fixture: `test ! -f cyan/fixtures/expected/base_only/CLAUDE.md`,
  `test ! -d cyan/fixtures/expected/base_only/.claude`.
- `base_llm` fixture:
  `[ "$(find cyan/fixtures/expected/base_llm/.claude/skills -name SKILL.md | wc -l)" = "7" ]`.

### Non-Functional Checks

- All `.sh` files in `templates/base/` and fixtures contain `#!/usr/bin/env bash` and
  `set -euo pipefail` (NFR8).
- `templates/base/.github/workflows/{ci,cd}.yaml` declare both `name:` and `on:` keys
  at the root (deep-merge contract for Plans 2/3).
- All YAML files single-document, plain-object root (NFR Domain Resolver Compatibility).

## Validation Approach

- **Immediate automated checks**:
  - `cd cyan && npx tsc --noEmit`.
  - `cyanprint test template .` (twice; second run for idempotency, AC1 partial).
  - `cyanprint test template . --update-snapshots && git diff --quiet cyan/fixtures/expected/`.
  - Per-fixture `find/grep/bash -n/ruby -ryaml` invocations.
  - `head -n1` and `grep -q 'preCommitPackages'` on shells.nix.
- **Post-release checks**: covered cumulatively in Plan 4 (post-release `cyan run` smoke
  on `base_only` is also Plan 4's responsibility since it depends on the published
  template, not this plan in isolation).
- **Manual checks**:
  - Read-through of `cyan.yaml` to confirm resolver `files:` globs match FR2.
  - Read-through of `templates/base/nix/shells.nix` and `nix/env.nix` for nix syntax
    sanity.
  - Read-through of one reusable workflow YAML to confirm `runs-on:` is the nscloud
    block, not `ubuntu-latest`.
  - Spot-check of `base_llm/CLAUDE.md` to confirm 7 H1 sections in alphabetical order.
