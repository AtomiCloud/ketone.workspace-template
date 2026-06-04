# Triage: Rewrite atomi/workspace template — composable additive folders with resolver-based merging

## Delivery Kind
pr

## Complexity
complex

## Assessment

This is a full rewrite of the atomi/workspace CyanPrint template into a composable additive
architecture: multiple template folders (base/, docker/, helm/, secret/) feed independent
processor pipelines, and four custom resolvers (atomi/json-yaml, atomi/md, atomi/ignore,
atomi/nix) merge overlapping files. The ticket is framed as a narrow "remaining work" scope,
but this branch is at `1428d55 feat: initial commit` with none of the prerequisites in place,
and even the only related sibling branch (`Adelphi-Liong/CU-86ex0pvna/...`) only contains
`templates/base/` plus one fixture — no `docker/`, no `helm/`, no `secret/`. **Decision
confirmed with user: option (a) — full rewrite from scratch on this branch.** Scope therefore
expands well beyond the ticket's literal text to include authoring the entire template
architecture: the new `cyan/index.ts`, `cyan/src/standard.ts`, `cyan.yaml` with all four
resolvers, every file under `templates/{base,docker,helm,secret}/`, all 9 snapshot fixtures,
and all 9 test cases in `test.cyan.yaml`. Realistic file count is 150–200 files touched or
created.

## Clarifications

- **Scope decision: option (a) — full rewrite from scratch.** Confirmed with user. We do
  not rely on the `86ex0pvna` branch as a prerequisite; this branch starts from `main`
  (initial commit) and produces the entire composable template in one PR.
- **Ticket VE1–VE7 are aspirational, not factual against this branch.** Treat the
  Verification Evidence section as describing the *target* end-state, not a baseline.
  Every "CONFIRMED" claim must be re-validated as we build, not assumed true.
- **`templates/docker/` and `templates/helm/` content authored from scratch.** No prior
  art available; we'll derive their contents from the ticket's FRs, ACs, and from
  observable behavior (CI/CD job names, hook names, skill names, Taskfile includes
  the ticket lists explicitly).

## Risks

- **High: scope vastly exceeds the ticket text.** The ticket reads as a 4-FR fix-up
  (~10 files); we are actually building 150–200 files in one PR. Estimation, review
  burden, and merge risk are all driven by the larger reality, not the ticket framing.
- **High: external resolver dependencies are opaque to us.** Behavior depends on
  `atomi/json-yaml`, `atomi/md`, `atomi/ignore`, `atomi/nix` resolvers and the
  `atomi/nix` template. Their exact merge semantics (nix `mergeShells` argument-list
  rule, ignore `### ` section parsing, md `# ` H1 boundaries, json-yaml deterministic
  ordering) drive whether generated output and snapshots are correct. We have no source
  for these in-tree, so any wrong assumption surfaces only at test time.
- **High: docker/ and helm/ folders authored without prior art.** No existing
  implementation to crib from. We'll derive contents from the ticket's FRs/ACs and from
  inferred conventions, but there's real risk of drifting from how the team actually
  expects these scaffolds to look (Dockerfile shape, helm chart structure, CI job names).
- **Moderate: snapshot brittleness.** Nine snapshot fixtures × every file in the merged
  output. Any drift in resolver merge order, nix formatting, YAML key ordering, or
  default processor behavior produces noisy diffs that look like test failures and
  thrash the PR.
- **Moderate: nix correctness across folders.** All `shells.nix` files must parse and
  share an identical argument list (the ticket says 4 args). Any drift between base,
  docker, helm causes the resolver to throw at generation time, not snapshot-compare
  time, so failures are global rather than localized.
- **Moderate: variable-syntax discipline.** `let__platform__` / `let__service__` must
  be the only variables; any stray `{{ }}` from the original scaffold or any
  unsubstituted `let__...__` marker fails AC9.
- **Low: ticket VE/AC drift from final reality.** Because VE1–VE7 are aspirational not
  factual, the ticket's specific claims (e.g. exact skill counts, exact CI job lists)
  may turn out subtly wrong as we build. We treat them as guidance, not contract.

## Verification

### Assumptions to Verify

- **`atomi/nix` resolver `mergeShells` signature requirement.** Ticket FR1 / NFR "Nix
  Resolver Compatibility" claims all `shells.nix` files across all folders must have
  identical 4-arg signatures `{ pkgs, packages, env, shellHook }:`. Source: the resolver's
  implementation. Need to read the resolver to confirm exact rule (does it match argument
  names? count? does it tolerate optional args?).
- **`atomi/json-yaml` resolver `arrayStrategy: concat` semantics.** Ticket assumes setup
  task `cmds` arrays from base + secret are concatenated, deterministic order by
  `(layer ASC, template ASC)`. Source: resolver implementation and any existing tests.
- **`atomi/md` resolver merge rules.** Ticket assumes H1 sections are merged. Need to
  confirm: ordering, deduplication of identical sections, what happens with conflicting
  same-titled sections.
- **`atomi/ignore` resolver `### ` section parsing.** Ticket assumes `### ` headers act as
  section boundaries with deduplication. Confirm exact boundary syntax (3 hashes vs 2 vs
  any depth).
- **`atomi/nix` template dependency.** Ticket assumes this dependency provides `flake.nix`
  and influences nix file generation. Need to confirm what files it contributes and how
  `cyan/nix/basic` / `cyan/nix/llm` answers gate behavior.
- **CyanPrint snapshot diff semantics.** `cyanprint test template . --update-snapshots`
  regenerates fixtures; the test runner then compares byte-for-byte. Confirm whether order
  of files within YAML/JSON outputs is canonicalised by the runner or by the resolver.
- **Whether `templates/docker/` and `templates/helm/` content exists somewhere.** The
  ticket places them out-of-scope, implying they exist. They are not in this branch, the
  `86ex0pvna` branch, nor any other local branch. Source: ask user where they live.

### Access Required

- **Source for `atomi/json-yaml`, `atomi/md`, `atomi/ignore`, `atomi/nix` resolvers** —
  either a registry-pull URL, repo path, or permission to fetch them from
  `https://api.zinc.sulfone.raichu.cluster.atomi.cloud/api/v1/`. Without this, FR1/AC5/AC7
  cannot be designed against truth.
- **Source for `atomi/nix` template** — to know what files it injects so we can correctly
  predict snapshot contents and avoid duplicating work.
- **Confirmation of where `templates/docker/` and `templates/helm/` content lives**, or
  explicit instruction that they are part of this ticket and need to be authored from
  scratch.
- **Decision from user about which scope interpretation (a / b / c) applies.**

### Testing Level
heavy

Snapshot-driven integration testing is the spec's primary verification mechanism. Nine test
cases, each running multiple `validate` commands (shell parse, YAML parse, file existence,
skill count, marker absence) plus byte-level snapshot comparison. Every feature combination
must be exercised because the resolver merging is the system under test, and bugs only
surface in multi-folder combinations. Manual spot-check of a generated project is also
warranted because snapshot tests can pass while still producing output that fails at runtime
(empty Dockerfile is exactly such a case — TD1).

### Validation Matrix

- **Automated immediate**:
  - `cyanprint test template .` — all 9 test cases green (snapshot equality + validate
    commands).
  - `cd cyan && npx tsc --noEmit` — TypeScript compiles.
  - `find . -name '*.nix' -exec nix-instantiate --parse {} +` across each generated fixture.
  - `ruby -ryaml -e 'YAML.safe_load(STDIN)'` over every YAML in every fixture.
  - `bash -n` over every generated `.sh`.
  - Grep for residual `let__` and `flake.nix` in every fixture.
- **Manual immediate**:
  - One-time eyeball of merged `CLAUDE.md`, `.gitignore`, `ci.yaml`, and `shells.nix` in
    the `all_features` fixture to confirm the merged output is semantically sensible, not
    just byte-equal to a snapshot we just regenerated.
  - Spot-check of `secret_only` Taskfile setup task to confirm `./scripts/local/secrets.sh`
    is actually appended (not replacing) base's setup commands.
- **Automated post-release**: none at the template-build layer; the template's generated
  output ships its own CI which exercises real builds — that effectively serves as a
  delayed integration check.
- **Manual post-release**:
  - Run `cyan run` against the published template at least once in each headline feature
    combination (base_only, all_features) and confirm `pls setup` / `direnv allow` /
    `pls helm:*` / `infisical run --env=dev -- env` all work end-to-end. This catches the
    known TD1/TD2/TD3 docker/helm runtime issues that snapshots cannot.
