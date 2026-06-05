# Spec: Rewrite atomi/workspace template — composable additive folders with resolver-based merging

## Summary

Rewrite the `atomi/workspace` CyanPrint template from initial commit into a composable
additive architecture. The template emits scaffolding by combining four conditionally-applied
folder processors (`templates/{base,docker,helm,secret}`), with four AtomiCloud resolvers
(`atomi/json-yaml`, `atomi/md`, `atomi/ignore`, `atomi/nix`) merging overlapping files
(CI/CD YAML, `Taskfile.yaml`, `CLAUDE.md`, `.gitignore`, `nix/*.nix`) across folders. Verified
end-to-end by 9 snapshot test cases in `test.cyan.yaml` covering every feature combination,
plus per-fixture validate commands (shell parse, YAML parse, file presence/absence, skill
counts, residual-marker grep).

## Verification Evidence

### VE1 — `atomi/nix` resolver throws on `shells.nix` argument-list mismatch

**Assumption**: All `shells.nix` files across all folders must have identical function
parameter lists; the resolver throws otherwise.

**Checked**: Source of `mergeShells` at
`https://github.com/AtomiCloud/ketone.nix-resolver/blob/main/cyan/src/merge-shells.ts`.

**CONFIRMED**. The function sorts each file's `functionArgs` and throws
`shells.nix function args mismatch: "[...]" vs "[...]"` when length or sorted contents
differ from the first file. There is no union, padding, or tolerance — strict equality.
This means every folder that contributes a `shells.nix` must use the same arg list
(`{ pkgs, packages, env, shellHook }:`).

### VE2 — `atomi/json-yaml` `arrayStrategy: concat` deterministic order is `(layer ASC, template ASC)`

**Assumption**: Concat ordering is deterministic across runs.

**Checked**: Source of resolver entry point at `ketone.json-yaml-resolver/index.ts`.

**CONFIRMED**. The resolver sorts inputs by `origin.layer` ascending, then
`origin.template` (string) ascending, then deep-merges via `smob` with `array: true`.
Single-document YAML only — multi-document YAML throws. Root must be a plain object —
arrays/scalars at root throw.

### VE3 — `atomi/md` resolver merges H1 sections, default `sectionOrder=alphabetical`, default `contentOrder=lowest-layer-first`

**Assumption**: H1 (`# `) headers act as section boundaries; same-titled sections merge.

**Checked**: Source at `ketone.md-resolver/index.ts`.

**CONFIRMED**. Sections are split on lines starting with `# ` (single `#`, single space,
content). Sections with identical headers are concatenated paragraph-by-paragraph using
`contentOrder` (defaulting to `lowest-layer-first`). The output is then re-ordered by
`sectionOrder` (defaulting to `alphabetical`). Preamble before the first H1 is preserved
as a header-less section. Both ordering strategies are configurable via resolver `config`.

### VE4 — `atomi/ignore` resolver is fully implemented (NOT a stub)

**Assumption**: `### ` section headers act as boundaries; patterns deduplicate within sections.

**Checked**: Source at `ketone.ignore-resolver/index.ts`. Note: the registry API description
("currently a stub") is stale — the implementation is complete.

**CONFIRMED**. Section boundary syntax is exactly `### ` (three hashes, single space).
The resolver supports backslash-line-continuation joining, comment stripping (preserving
`### ` and `#### source:` markers), inline source tags `### node [tpl-a, tpl-b]`, and
per-section pattern deduplication. Output emits `#### source: tpl-a, tpl-b` lines for
provenance.

### VE5 — `atomi/nix` template dependency contributes `flake.nix`

**Assumption**: The template should NOT vendor `flake.nix`; it comes from the dependency.

**Checked**: `https://github.com/AtomiCloud/ketone.nix-template` and registry metadata.

**CONFIRMED**. The dependency contributes `flake.nix` plus optional CLAUDE/skills layer
gated by `cyan/nix/llm`. Generated output must contain zero `flake.nix` files in the
template's own contribution (verified by `test ! -f flake.nix` in every snapshot's
validate commands). The template invokes the dependency via `templates:` in `cyan.yaml`
with `cyan/nix/basic: 'yes'`, `cyan/nix/llm: 'no'`.

### VE6 — Base scaffold from sibling branch `86ex0pvna` has the buggy 5-arg `shells.nix`

**Assumption**: The base scaffold currently has `{ pkgs, packages, env, shellHook, preCommitPackages }:`
which is incompatible with helm's 4-arg signature.

**Checked**: `git show Adelphi-Liong/CU-86ex0pvna/Rewrite-atomiworkspace-template:templates/base/nix/shells.nix`.

**CONFIRMED**. The 5-arg signature exists on `86ex0pvna`. The lint env group at
`templates/base/nix/env.nix` already includes `pre-commit, treefmt, gitlint, shellcheck,
sg, actionlint, go-task` — the same packages `preCommitPackages` would have provided.
Therefore the spec's resolution is to author the base scaffold with the 4-arg signature
from the start (no separate "fix and regenerate" step needed since this branch starts
from initial commit).

### VE7 — Reference helm scaffold from `AtomiCloud/ketone.helm` uses 4-arg `shells.nix` and adds `infrautils`/`infralint`

**Assumption**: Helm content authored in this template should align with team
conventions for helm-related nix/CI shape.

**Checked**: `gh api repos/AtomiCloud/ketone.helm/contents/templates/base/nix/shells.nix` and
`.../env.nix`.

**CONFIRMED**. Reference shells.nix uses `{ pkgs, packages, env, shellHook }:` (4 args)
matching the resolver requirement. Reference env.nix adds `infrautils` to `system`,
`infralint` to `lint`, and `infisical, skopeo` to `main`. We will follow these
conventions in `templates/helm/nix/env.nix` so the merged output remains coherent.

### VE8 — This branch is at `1428d55 feat: initial commit` — no prerequisites in place

**Assumption**: Ticket framing presumes `templates/{base,docker,helm}` already exist and
this work is "remaining gaps". Triage decision (option a, confirmed with user) overrides
this framing — full rewrite from scratch.

**Checked**: `git log` and `git ls-tree HEAD` on this branch.

**CONFIRMED**. HEAD has 24 files: SDK skills, scripts, basic CyanPrint scaffolding, a
single `templates/README.md`. No `templates/base/`, `templates/docker/`, `templates/helm/`,
`templates/secret/`, no `cyan.yaml` resolver config, no fixtures, no `cyan/src/standard.ts`,
no `test.cyan.yaml` test cases beyond the throwaway `basic_generation`. Scope therefore
expands beyond the ticket text to author the entire composable architecture.

### VE9 — Sibling branches `-2`, `-3`, `-4` are empty (24 files each, identical to HEAD)

**Assumption**: No prior art elsewhere on this repo.

**Checked**: `git ls-tree -r <branch> --name-only | wc -l` on each.

**CONFIRMED**. All three are identical to initial commit — no salvageable progress.
Only `86ex0pvna` carries any prior art (`templates/base/` + 1 fixture).

### VE10 — `docker/` and `helm/` content has no in-repo prior art; `ketone.helm` is the closest reference

**Assumption**: Per triage, docker/ and helm/ content must be authored from scratch.

**Checked**: Listed all branches; queried `gh repo list AtomiCloud --limit 200` for any
existing docker/helm scaffold; inspected `ketone.helm` (the closest reference repo).

**CONFIRMED**. The team's `ketone.helm` repo is the canonical reference for helm-shaped
nix/Taskfile/CI conventions. We will spot-check structural conventions there
(per the user's chosen "ticket + spot-check existing repos" approach) but author the
content fresh against this template's own variable-syntax (`let__platform__`,
`let__service__`) and resolver constraints.

### VE11 — `infisical run --env=dev` without trailing `-- <command>` does not propagate secrets to parent shell

**Assumption**: The Infisical CLI documentation must show subprocess syntax.

**Checked**: Infisical CLI docs at `https://infisical.com/docs/cli/commands/run` (general
behavior) and ticket VE5 reasoning.

**CONFIRMED**. `infisical run [options] -- [command]` runs a subprocess with injected
secrets. Without the trailing command the process exits immediately and secrets are not
exported to the calling shell. Documentation in `templates/secret/docs/developer/standard/infisical.md`
must show the subprocess form. The bare `infisical run --env=dev` line in
`scripts/local/secrets.sh` is acceptable as a one-shot fetch (login on the previous
line is the persistent action), but documentation aimed at users must show
`infisical run --env=dev -- <command>`.

## Requirements

### Functional Requirements

#### FR1 — Template entry point with composable additive processors

Author `cyan/index.ts` so that:

- It calls `standardPrompts(i)` from `cyan/src/standard.ts`, which returns
  `{ platform, service, llm, docker, helm, secret }`.
- It declares a `varSyntax` of `[['let__','__'], ['// let__','__'], ['# let__','__']]`.
- It builds an `exclude` array of `['**/CLAUDE.md', '**/.claude/**/*', '**/.claude/**/*.*']`
  when `llm === false`, otherwise `[]`.
- It always pushes a `cyan/default` processor for `templates/base` with `GlobType.Template`
  and the `exclude` array above.
- It conditionally pushes `cyan/default` processors for `templates/docker`,
  `templates/helm`, `templates/secret` when their respective answers are `true`, with
  the same `exclude` array.
- It returns `{ processors, plugins: [] }`.

Author `cyan/src/standard.ts` so that the prompt sequence is:

1. `i.text('Platform', 'atomi/platform', 'LPSM Service Tree Platform')`, lowercased.
2. `i.text('Service', 'atomi/service', 'LPSM Service Tree Service')`, lowercased.
3. `i.confirm('Enable LLM Support', 'atomi/llm', 'Add CLAUDE.md and Claude skills')`.
4. `i.confirm('Enable Docker', 'atomi/docker', 'Enable Docker Integration')`.
5. `i.confirm('Enable Helm', 'atomi/helm', 'Enable Helm Chart Integration')`.
6. `i.confirm('Enable Secret Management', 'atomi/secret', 'Enable Secret Management')`.

The signature
`export async function standardPrompts(i: IInquirer): Promise<{platform: string; service: string; llm: boolean; docker: boolean; helm: boolean; secret: boolean}>`.

`cd cyan && npx tsc --noEmit` must succeed.

#### FR2 — `cyan.yaml` declares all four resolvers and the `atomi/nix` template dependency

Author `cyan.yaml` to include:

- `templates:` with one entry `atomi/nix` carrying answers
  `{ cyan/nix/basic: 'yes', cyan/nix/llm: 'no' }`.
- `processors: [cyan/default]`.
- `plugins: []`.
- `resolvers:` with exactly four entries:
  - `atomi/json-yaml` with `config: { arrayStrategy: concat }` and files
    `['.github/workflows/ci.yaml', '.github/workflows/cd.yaml', '.github/workflows/release.yaml',
    '.github/dependabot.yml', 'Taskfile.yaml', '.coderabbit.yaml', 'atomi_release.yaml']`.
  - `atomi/md` with `config: {}` and files `['CLAUDE.md', 'README.md', '.envrc']`.
  - `atomi/ignore` with `config: {}` and files `['.gitignore', '.dockerignore']`.
  - `atomi/nix` with `config: {}` and files
    `['nix/packages.nix', 'nix/env.nix', 'nix/shells.nix', 'nix/fmt.nix', 'nix/pre-commit.nix']`.
- `commands: ['chmod +x scripts/ci/*.sh 2>/dev/null || true']`.
- `build:` block as on `86ex0pvna`.

#### FR3 — `templates/base/` scaffold (full content, 4-arg `shells.nix` from the start)

Author `templates/base/` with the file set demonstrated on `86ex0pvna`, with the
following corrections applied:

- `templates/base/nix/shells.nix` MUST use `{ pkgs, packages, env, shellHook }:` (4 args).
  No `preCommitPackages` parameter. `buildInputs` lists are
  - `default`: `system ++ main ++ lint ++ dev`
  - `ci`: `system ++ main ++ lint`
  - `releaser`: `system ++ main ++ lint ++ releaser`
- `templates/base/nix/env.nix` keeps the existing lint group (`pre-commit, treefmt,
  gitlint, shellcheck, sg, actionlint, go-task`) — this group provides what
  `preCommitPackages` previously did.
- All reusable workflows under `templates/base/.github/workflows/⚡reusable-*.yaml`
  use the nscloud runner: `nscloud-ubuntu-22.04-amd64-32x64-with-cache`,
  `nscloud-cache-size-50gb`, `nscloud-cache-tag-atomi-nix-store-cache`.
- Skills under `templates/base/.claude/skills/` are exactly:
  `ci-cd-workflows`, `conventional-commits`, `linting`, `semantic-release`,
  `service-tree`, `shell-conventions`, `taskfile-conventions` (7 skills).
- `templates/base/CLAUDE.md` uses `# ` (H1) section headers (one per topic).
- `templates/base/.gitignore` uses `### ` section headers.
- All template variables use `let__platform__`, `let__service__`. Zero `{{ }}` or
  `<%= %>` markers anywhere in `templates/base/`.

The complete file set (mirroring `86ex0pvna` minus the shells.nix bug) is:

```
templates/base/
├── .claude/skills/{ci-cd-workflows,conventional-commits,linting,semantic-release,service-tree,shell-conventions,taskfile-conventions}/SKILL.md
├── .coderabbit.yaml
├── .envrc
├── .github/actionlint.yaml
├── .github/dependabot.yml
├── .github/workflows/{ci,cd,release}.yaml
├── .github/workflows/⚡reusable-{precommit,release}.yaml
├── .github/workflows/🛡️merge-gatekeeper.yml
├── .gitignore
├── .gitlint
├── .prettierrc.yaml
├── CLAUDE.md
├── Taskfile.yaml
├── atomi_release.yaml
├── docs/developer/CommitConventions.md
├── docs/developer/standard/{ci-cd,conventional-commits,linting,semantic-release,service-tree,shell-scripts,taskfile}.md
├── nix/{env,fmt,packages,pre-commit,shells}.nix
└── scripts/ci/{pre-commit,release,setup}.sh
```

#### FR4 — `templates/docker/` scaffold

Author `templates/docker/` with content sufficient to satisfy the resolver-merge
expectations the ticket calls out (CI/CD docker job, Taskfile docker include, docker
push skill, docker-related nix additions). Concrete contents:

- `templates/docker/.github/workflows/ci.yaml` — partial YAML adding a `docker-build`
  job under `jobs:` and matching `name: CI` / `on: push:` so `atomi/json-yaml` deep-merges
  cleanly with base's `ci.yaml`.
- `templates/docker/.github/workflows/cd.yaml` — partial YAML adding a `docker-push`
  job; merges into base's `cd.yaml`.
- `templates/docker/.github/dependabot.yml` — adds `package-ecosystem: docker` entry.
- `templates/docker/Taskfile.yaml` — partial with
  `includes: { docker: tasks/Taskfile.docker.yaml }` (merges into base via concat).
- `templates/docker/tasks/Taskfile.docker.yaml` — full taskfile partial with
  docker-related tasks (`docker:build`, `docker:push`, `docker:lint`).
- `templates/docker/scripts/ci/docker-build.sh`, `templates/docker/scripts/ci/docker-push.sh` —
  shell scripts with `#!/usr/bin/env bash` and `set -euo pipefail`.
- `templates/docker/.dockerignore` — uses `### ` section headers, ignores `node_modules`,
  `.git`, etc.
- `templates/docker/CLAUDE.md` — single H1 `# Docker` section linking to docs.
- `templates/docker/.claude/skills/docker-push/SKILL.md` — skill referencing docker
  build/push conventions.
- `templates/docker/docs/developer/standard/docker.md` — docs file.
- `templates/docker/nix/env.nix` — partial adding any docker-only packages (e.g. `skopeo`)
  into the appropriate group; merges via `atomi/nix` env category-union.
- `templates/docker/nix/pre-commit.nix` — partial adding any docker-related hooks (e.g.
  `a-hadolint`) merged via the resolver's hook deep-merge.
- `templates/docker/nix/shells.nix` — MUST use `{ pkgs, packages, env, shellHook }:`
  (4 args, identical signature to base).
- `templates/docker/infra/Dockerfile` — minimal multi-stage Dockerfile scaffold
  (NOT 0 bytes — TD1 from the ticket is excluded from this spec, but we will not
  ship a literally-empty file as that breaks the snapshot's own validity).

Spot-check shape against `AtomiCloud/ketone.helm` for cross-reference (workflow name
casing, runs-on style, pre-commit hook naming convention) but DO NOT attempt to mirror
that repo's full helm-specific architecture inside the docker folder.

#### FR5 — `templates/helm/` scaffold

Author `templates/helm/` mirroring the helm-shaped conventions in `AtomiCloud/ketone.helm`
adapted for this template's variable syntax and resolver constraints. Concrete contents:

- `templates/helm/.github/workflows/ci.yaml`, `cd.yaml` — partial YAMLs adding
  `helm-lint`, `helm-publish` jobs.
- `templates/helm/.github/dependabot.yml` — entries for any helm-related ecosystems.
- `templates/helm/Taskfile.yaml` — `includes: { helm: tasks/Taskfile.helm.yaml }`.
- `templates/helm/tasks/Taskfile.helm.yaml` — helm tasks (`helm:lint`, `helm:docs`,
  `helm:push`).
- `templates/helm/scripts/ci/helm-{lint,publish}.sh` — shell scripts.
- `templates/helm/CLAUDE.md` — single H1 `# Helm` section.
- `templates/helm/.claude/skills/helm-push/SKILL.md`.
- `templates/helm/docs/developer/standard/helm.md`.
- `templates/helm/infra/root_chart/{Chart.yaml,values.yaml,templates/.gitkeep}` — minimal
  helm chart scaffold sufficient for `helm template` to parse (per-landscape values
  files are TD2 and out of scope).
- `templates/helm/nix/env.nix` — adds `infrautils` to `system`, `infralint` to `lint`,
  `yq` (or moved to a docker-only group if cross-folder analysis says so) into a
  group that merges with base's env.
- `templates/helm/nix/pre-commit.nix` — adds `a-helm-lint`, `a-helm-docs` hooks.
- `templates/helm/nix/shells.nix` — MUST use the 4-arg signature.

Spot-check `AtomiCloud/ketone.helm` for chart shape; do not vendor that repo's full
content. Adapt to this template's variable syntax.

#### FR6 — `templates/secret/` scaffold

Author `templates/secret/` with these files:

- `templates/secret/scripts/local/secrets.sh`:
  ```bash
  #!/usr/bin/env bash
  set -euo pipefail
  INFISICAL_API_URL="https://secrets.atomi.cloud" infisical login
  infisical run --env=dev
  ```
- `templates/secret/Taskfile.yaml`:
  ```yaml
  version: '3'
  includes:
    secret: tasks/Taskfile.secret.yaml
  tasks:
    setup:
      cmds:
        - ./scripts/local/secrets.sh
  ```
  When merged with base's `Taskfile.yaml` via `arrayStrategy: concat`, the secret
  folder appends `./scripts/local/secrets.sh` to base's existing `setup.cmds` list
  (rather than replacing it).
- `templates/secret/tasks/Taskfile.secret.yaml` — taskfile partial with secret-related
  tasks (`secret:fetch`, `secret:scan`).
- `templates/secret/.gitignore`:
  ```
  ### Secrets
  .env
  .env.*
  *.tfvars
  .infisical.json
  ```
  Uses `### ` section header per `atomi/ignore` resolver convention (VE4).
- `templates/secret/docs/developer/standard/infisical.md` — documents Infisical at
  `https://secrets.atomi.cloud`. MUST show the subprocess form
  `infisical run --env=dev -- <command>` with concrete examples
  (`infisical run --env=dev -- env | grep MY_SECRET`,
  `infisical run --env=dev -- pls test`). Explicitly states that bare
  `infisical run --env=dev` (no `-- <command>`) does not propagate secrets to the
  parent shell — it only runs as a one-shot subprocess wrapper.
- `templates/secret/CLAUDE.md`:
  ```markdown
  # Secret Management

  This project uses Infisical for secret management. Use `pls setup` to authenticate
  and fetch secrets. See [docs/developer/standard/infisical.md](docs/developer/standard/infisical.md)
  for details.
  ```
  Uses `# ` (H1) section header per `atomi/md` resolver convention.
- `templates/secret/.claude/skills/infisical/SKILL.md` — standard skill format with
  frontmatter referencing the docs.

NO nix files in the secret folder. The secret folder does not contribute to
`packages.nix`, `env.nix`, `pre-commit.nix`, or `shells.nix`. (The `infisical` package
is already in base's env.nix lint group via the `a-infisical` and `a-infisical-staged`
pre-commit hooks.)

#### FR7 — `test.cyan.yaml` with 9 test cases

Author `test.cyan.yaml` with exactly 9 test cases. Each test case has:

- `name: <case>`
- `expected.type: snapshot`, `expected.value.path: cyan/fixtures/expected/<case>`
- `answer_state` for the 6 prompts (`atomi/{platform,service,llm,docker,helm,secret}`)
  plus `cyan/nix/basic: 'yes'`, `cyan/nix/llm: 'no'`. `atomi/platform` and
  `atomi/service` are `test-platform` and `test-service`.
- `validate:` list with the universal commands plus case-specific assertions.
- `deterministic_state: {}`.

The 9 test cases:

| Case            | llm | docker | helm | secret | Skill count | Notable assertions                                                                                       |
|-----------------|-----|--------|------|--------|-------------|----------------------------------------------------------------------------------------------------------|
| `base_only`     | no  | no     | no   | no     | 0           | `test ! -f CLAUDE.md`, `test ! -d .claude`                                                               |
| `base_llm`      | yes | no     | no   | no     | 7           | `find .claude/skills -name SKILL.md \| wc -l = 7`                                                        |
| `docker_only`   | yes | yes    | no   | no     | 8           | docker job in `ci.yaml`, docker-push skill, Taskfile docker include                                      |
| `helm_only`     | yes | no     | yes  | no     | 9           | helm job in `ci.yaml`/`cd.yaml`, helm-push skill, Taskfile helm include, infrautils/infralint in env.nix |
| `secret_only`   | yes | no     | no   | yes    | 8           | `./scripts/local/secrets.sh` exists, `### Secrets` section in `.gitignore`, infisical skill              |
| `no_llm_docker` | no  | yes    | no   | no     | 0           | docker present, but `test ! -f CLAUDE.md`, `test ! -d .claude`                                           |
| `docker_helm`   | yes | yes    | yes  | no     | 9           | merged docker + helm CI jobs, both Taskfile includes, both nix hook sets                                 |
| `all_features`  | yes | yes    | yes  | yes    | 10          | all jobs merged, all includes, all hooks, all skills, secrets `### ` section + Infisical docs            |
| `no_llm_all`    | no  | yes    | yes  | yes    | 0           | all features present but `test ! -f CLAUDE.md` and `test ! -d .claude` everywhere                        |

Universal validate commands (POSIX-only; nix-instantiate is NOT required at test time
because the runner may not have nix on PATH — instead, parse generated nix indirectly
via the `cyanprint` snapshot equality check):

```bash
find . -name '*.sh' -exec bash -n {} +                 # All shell scripts have valid syntax
grep -q '^tasks:' Taskfile.yaml                        # Taskfile has tasks key (when applicable)
test ! -f flake.nix                                    # No flake.nix from this template (atomi/nix template injects it)
! grep -rqE 'let__[a-zA-Z_]+__' .                      # Zero unsubstituted let__ markers
ruby -ryaml -e 'YAML.safe_load(STDIN)' < <yaml-file>   # YAML files parse (per-file)
```

The flake.nix assertion is `test ! -f flake.nix` because the snapshot fixture captures
THIS template's contribution only — the `atomi/nix` template dependency injects flake.nix
at the cyanprint orchestrator layer, not into our snapshot.

Per-case validate commands lift the feature-specific assertions in the table above.

#### FR8 — Nine snapshot fixtures under `cyan/fixtures/expected/`

Generate the 9 snapshot fixture directories via `cyanprint test template . --update-snapshots`,
then commit them to the repo:

```
cyan/fixtures/expected/{base_only,base_llm,docker_only,helm_only,secret_only,
                       no_llm_docker,docker_helm,all_features,no_llm_all}/
```

Each directory MUST contain exactly the files this template produces for that feature
combination (after resolver merging). No `flake.nix` (it's contributed by the
`atomi/nix` template dependency, not this template). No `let__` markers anywhere.

After committing, a fresh `cyanprint test template .` (without `--update-snapshots`)
must exit 0 with all 9 cases passing snapshot equality + validate commands.

#### FR9 — Variable syntax discipline

The only variable substitution syntax used in `templates/**/*` is the `let__var__`
form. The `varSyntax` in `cyan/index.ts` is:

```typescript
const varSyntax: [string, string][] = [
  ['let__', '__'],         // bare (markdown, yaml, generic text)
  ['// let__', '__'],      // TypeScript/JavaScript/C# line comments
  ['# let__', '__'],       // Python/Shell/Nix line comments
];
```

Variables: `let__platform__`, `let__service__`. Zero `{{ }}`, zero `<%= %>`, zero
`var__...__` in `templates/**`. Test validate commands assert no residual `let__`
markers in generated output.

Note: the project's own `CLAUDE.MD` and `cyan/README.MD` may continue to use
illustrative `{{var}}` examples for documentation purposes — those are not in
`templates/**` so they don't conflict.

#### FR10 — CI runner standardization

All reusable GitHub Actions workflows generated by this template (`templates/base/.github/workflows/⚡reusable-*.yaml`,
plus any `templates/{docker,helm,secret}/.github/workflows/⚡reusable-*.yaml`) MUST use:

```yaml
runs-on:
  - nscloud-ubuntu-22.04-amd64-32x64-with-cache
  - nscloud-cache-size-50gb
  - nscloud-cache-tag-atomi-nix-store-cache
```

Non-reusable workflows (e.g. `🛡️merge-gatekeeper.yml`) may use `ubuntu-latest`.

#### FR11 — `cyan.yaml` resolver file globs cover every cross-folder file

For every file path that exists in two or more of `templates/{base,docker,helm,secret}/`,
the corresponding glob in `cyan.yaml.resolvers[*].files` MUST cover it. This is the
explicit invariant that prevents "second-write wins / first-write wins" silent failures.
The current resolver glob list (from FR2) is the canonical set. If during implementation
we find a cross-folder file path NOT in the glob list, we add it before generating
fixtures.

### Non-Functional Requirements

1. **Linting** — Applies. All generated YAML must parse as a single document with
   `ruby -ryaml -e 'YAML.safe_load(STDIN)'`. All generated `.sh` files must pass
   `bash -n`. Nix files are validated indirectly via snapshot equality (the
   `atomi/nix` resolver throws at generation time on malformed input). No new lint
   rule additions to repo lint config; existing config covers the new code.

2. **Building** — Applies. `cd cyan && npx tsc --noEmit` must succeed (TypeScript
   entry point compiles). `cyanprint test template .` must exit 0. No new build
   step beyond what the meta-template already does (`bun install`, `tsc`).

3. **Unit Testing** — Does NOT apply. CyanPrint templates use snapshot testing as
   the primary verification mechanism. The lambda in `cyan/index.ts` is small enough
   that the integration tests cover its behavior fully.

4. **Integration Testing** — Applies; this IS the primary mechanism. 9 test cases
   in `test.cyan.yaml` exercise every feature combination. Each runs:
   - Snapshot byte-equality against `cyan/fixtures/expected/<case>/`
   - Universal validate commands (shell parse, YAML parse, marker absence)
   - Case-specific validate commands (file presence, skill counts, section presence)

5. **End-to-End Testing** — Does NOT apply at template-build time. Post-release
   E2E is `cyan run` against the published template followed by `pls setup` /
   `direnv allow` / `pls helm:*` / `infisical run --env=dev -- env` in the
   generated project — listed under post-release manual validation, not blocking
   merge.

6. **Documentation** — Applies. Each folder contributes `CLAUDE.md` H1 sections
   (merged by `atomi/md`), `docs/developer/standard/*.md` files (per-folder, no
   merging needed since paths don't collide), and skill SKILL.md files. The
   `infisical.md` MUST show subprocess syntax `infisical run --env=dev -- <command>`.
   No update to top-level `CLAUDE.MD` (the template-author's docs) needed beyond
   what already exists.

7. **Observability** — Does NOT apply. This is a template generator; no runtime
   service, no metrics/logs/alerts to configure.

8. **Invariant Checking** — Applies. Invariants verified by validate commands:
   - All YAML files parse single-document (enforced by `atomi/json-yaml` and
     by per-file `ruby -ryaml`).
   - All shell scripts have `#!/usr/bin/env bash` shebang and `set -euo pipefail`
     (enforced by base's pre-commit hook `a-shellcheck` plus our `bash -n`).
   - `### ` section headers in `.gitignore`/`.dockerignore` (required by
     `atomi/ignore`); `# ` H1 in CLAUDE.md (required by `atomi/md`).
   - All `shells.nix` files across folders have identical 4-arg signature
     (enforced by `atomi/nix mergeShells` throwing at generation).
   - Zero unsubstituted `let__` markers, zero `flake.nix` in any fixture.
   - CI/CD partial YAMLs preserve `name:` and `on:` so `atomi/json-yaml` deep-merge
     produces a coherent single workflow.

9. **Security** — Does NOT apply. The template emits scaffolding. The `secret/`
   folder integrates Infisical (an external secret manager) but does not implement
   authentication itself. No user-input handling, no auth/authz, no data at rest
   or in transit. The generated `infisical.md` SHOULD warn that `.env` files are
   gitignored and that bare `infisical run --env=dev` does not propagate secrets
   (a footgun, not a vulnerability).

10. **Performance** — Does NOT apply. Template generation is one-time per project.
    Snapshot test suite runs in seconds; no benchmarking needed.

11. **Backwards Compatibility** — Applies (breaking change accepted). This is a
    full rewrite of `atomi/workspace`. Question IDs, prompt order, and generated
    file shapes will all differ from prior versions. Users re-running the template
    will see different prompts. No migration path is provided.

12. **Accessibility** — Does NOT apply. No UI is rendered.

**Domain-specific NFR — Resolver compatibility**: All generated files MUST conform
to the syntactic constraints the four resolvers impose. Specifically:
- `atomi/json-yaml`: single-document YAML, plain-object root.
- `atomi/md`: `# ` (H1, single hash + space + content) for section boundaries.
- `atomi/ignore`: `### ` (three hashes + space) for section boundaries.
- `atomi/nix mergeShells`: identical function arg list across all `shells.nix` files
  (enforced as an invariant by VE1).

**Domain-specific NFR — Determinism of merged output**: All resolvers sort by
`(layer ASC, template ASC)`. The order processors are pushed in `cyan/index.ts`
(base → docker → helm → secret) sets the layer numbering. Snapshots capture this
deterministic order and a reordering of processor pushes would invalidate them.
The processor push order in FR1 is canonical: base, docker (if), helm (if),
secret (if).

## Acceptance Criteria

**AC1**: `cyanprint test template .` exits 0 with all 9 test cases passing.
Run twice in succession to confirm idempotency: second run also exits 0.

**AC2**: `cd cyan && npx tsc --noEmit` exits 0.

**AC3**: `cyan/index.ts` and `cyan/src/standard.ts` are present and the prompt
sequence in `cyan/src/standard.ts` matches FR1 exactly (6 prompts in the listed
order, with the listed IDs and labels).

**AC4**: `cyan.yaml` includes `templates: [{template: atomi/nix, answers: {...}}]`
and the four resolvers as specified in FR2. `grep -c 'resolver:' cyan.yaml` ≥ 4.

**AC5**: `templates/base/nix/shells.nix` first line is exactly
`{ pkgs, packages, env, shellHook }:`. The string `preCommitPackages` does not
appear in the file. All four `nix/shells.nix` files (base, docker, helm) have
identical first-line signatures.

**AC6**: All 9 fixture directories exist under `cyan/fixtures/expected/` and
contain the file shapes required by their feature combinations (per FR7 table).
For each fixture:
- `! grep -rqE 'let__[a-zA-Z_]+__' cyan/fixtures/expected/<case>/` exits 0
- `test ! -f cyan/fixtures/expected/<case>/flake.nix` exits 0
- `find cyan/fixtures/expected/<case> -name '*.sh' -exec bash -n {} +` exits 0
- `find cyan/fixtures/expected/<case> -name '*.yaml' -exec ruby -ryaml -e 'YAML.safe_load(File.read(ARGV[0]))' {} \;`
  succeeds for every YAML file

**AC7** (`secret_only` Taskfile composition): in
`cyan/fixtures/expected/secret_only/Taskfile.yaml`, the `tasks.setup.cmds` array
contains BOTH base's existing setup commands AND `./scripts/local/secrets.sh`
(appended via `arrayStrategy: concat`). The file is parseable as single-document
YAML.

**AC8** (`all_features` merge correctness): in
`cyan/fixtures/expected/all_features/`:
- `Taskfile.yaml` includes `docker:`, `helm:`, and `secret:` entries in `includes:`.
- `.github/workflows/ci.yaml` has jobs from base (precommit), docker (docker-build),
  and helm (helm-lint).
- `.github/workflows/cd.yaml` has jobs from base (placeholder), docker (docker-push),
  and helm (helm-publish).
- `.gitignore` contains `### ` sections from base (macOS, Windows, Linux, IDE,
  Project) AND from secret (`### Secrets`), with within-section deduplication.
- `CLAUDE.md` contains H1 sections from base (CI/CD, Conventional Commits, etc.) +
  docker (Docker) + helm (Helm) + secret (Secret Management), sorted alphabetically
  per the `atomi/md` default `sectionOrder`.
- Skill count: `find .claude/skills -name SKILL.md | wc -l` = 10.
- `nix/shells.nix` first line is `{ pkgs, packages, env, shellHook }:`.

**AC9** (LLM gating discipline): `no_llm_all` fixture has `atomi/llm: false` and
all three feature toggles `true`. It MUST contain:
- `test ! -f CLAUDE.md` (no merged CLAUDE.md anywhere)
- `test ! -d .claude` (no .claude directory at all)
- All other feature artifacts present (docker job in CI, helm chart, secret script,
  etc.)

**AC10** (Infisical doc correctness): `cyan/fixtures/expected/secret_only/docs/developer/standard/infisical.md`
contains the literal string `infisical run --env=dev -- ` (with trailing `-- `).
Bare `infisical run --env=dev` followed by a newline does NOT appear as primary
documented usage (it may appear in `scripts/local/secrets.sh` only).

**AC11** (Snapshot stability): A second invocation of
`cyanprint test template . --update-snapshots` followed by `git status` produces
no diff under `cyan/fixtures/expected/`. (Confirms determinism — no time-of-day,
random-UUID, or machine-specific drift.)

## Out of Scope

- **Runtime-specific folders** (`go/`, `dotnet/`, `bun/`) — deferred to a future
  runtime template.
- **Runtime prompt** (None/Go/.NET/Bun selector) — out of this spec; this template
  has no runtime selection.
- **`⚡reusable-cyanprint.yaml`** — may move to `atomi/cyan` template in follow-up.
- **`flake.nix` in this template** — provided exclusively by the `atomi/nix` template
  dependency.
- **Publishing the template** (`cyanprint push`) — this spec covers implementation
  + testing only.
- **Post-release validation** (running `cyan run` against the published template,
  verifying real GitHub Actions runs, real `pls helm:*` execution) — not blocking
  merge.
- **Exact prose wording** in CLAUDE.md sections or developer/standard/*.md docs —
  content must be accurate; specific wording is implementation detail.
- **Per-landscape helm values files** (`values-dev.yaml`, etc.) — TD2 from the
  ticket; deferred.
- **Helm CD `yq` PATH dependency** — TD3 from the ticket; deferred.
- **Non-empty production-grade `Dockerfile` content** — the docker fixture ships
  a minimal multi-stage scaffold that builds a hello-world image; full
  production Dockerfile shape is deferred. (This intentionally departs from the
  ticket's TD1 framing — we author a non-zero file rather than ship a literal
  empty file that fails any `docker build` smoke test.)
- **Modifications to top-level `CLAUDE.MD`, `cyan/README.MD`, `scripts/publish.sh`,
  `scripts/setup-ubuntu.sh`** — these are template-author-facing files, not
  generated-output. Out of scope.
