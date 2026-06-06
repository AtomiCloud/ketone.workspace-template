# Spec: CI/CD rework — slim Taskfile, Nix-driven scripts, two-trigger Docker/Helm, secret dev env

## Summary

Rework the generated-project CI/CD and developer-environment scaffolding emitted by the
`atomi/workspace` template across the `base`, `docker`, `helm`, and `secret` folder layers:

1. **Slim the base Taskfile** to `setup` + `lint` only (drop the `test`/`build`/`clean`
   `echo` placeholders). Docker/Helm/Secret task namespaces stay status quo.
2. **Make CI/CD scripts the source of truth, run through Nix.** Workflows become thin
   runners that invoke `nix develop .#<shell> -c ./scripts/ci/<script>.sh`, matching the
   existing `⚡reusable-precommit.yaml` / `⚡reusable-release.yaml` pattern and the
   `ci-cd.md` doc. Skills (`docker-push`, `helm-push`, `infisical`) document the scripts.
3. **Add `infisical` to the dev shell** when the `secret` layer is enabled. The `secret`
   folder currently has **no `nix/` folder**, so `infisical` never reaches any shell's
   `buildInputs`. Add `templates/secret/nix/{env,packages,shells,pre-commit}.nix`.
4. **Docker & Helm each gain two triggers:**
   - **CI (every push/commit):** rebuild **both** image and chart, **cached**, tagged
     per-commit (`<sha6>-<branch>`, plus `<branch>` and `latest` on the default branch).
   - **CD (on `v*.*.*` tag created by semantic release):** **do not rebuild** — re-tag the
     already-built commit Docker image(s) to the semver, and repackage the Helm chart(s)
     at the semver. Multi-artifact ("all of them"), no architectural cap on count.
5. **nscloud-compatible fast builds:** all four jobs run on Namespace (nscloud) runners.
   Docker uses the Namespace buildx builder for fast cached builds; Helm uses Nix
   (`nix develop .#helm`) for `helm`/`yq`. Docker and Helm logic stay in **separate scripts**.
6. **Remove the no-op `setup.sh`** (`echo "Completed"`) and make `setup` composable across
   layers under the Taskfile concat-merge rules.

Verified end-to-end by the existing 9 snapshot test cases in `test.cyan.yaml` (regenerated
fixtures) plus per-fixture `validate` commands, and by a real `cyanprint try` generation that
is shell-parsed and YAML-parsed.

## Verification Evidence

### VE1 — Nix-registry bundle contents (which package provides which binary)

**Checked**: `AtomiCloud/nix-registry@v2` `binWrapper/{atomiutils,infrautils,infralint}.nix`.

**CONFIRMED**:
- `atomiutils` → `jq`, `yq-go` (provides `yq`) + general CLI utils.
- `infrautils` → `kubernetes-helm` (`helm`), `kubectl`, `docker`, `skopeo`.
- `infralint` → `helm-docs`, `helmlint`.

Implication: a shell composed of `system ++ lint` in a **helm-enabled** project resolves to
`atomiutils + infrautils + <base lint> + infralint`, i.e. it has `helm`, `yq`, `helm-docs`,
`skopeo`, `docker`, `kubectl`. This is the toolset the Helm CI/CD scripts need.

### VE2 — `atomi/nix` `shells.nix` merge semantics (union of names, union of buildInputs)

**Checked**: `AtomiCloud/ketone.nix-resolver` `cyan/src/merge-shells.ts`.

**CONFIRMED**:
- Function args must be **identical** (sorted equality) across every folder's `shells.nix`,
  else the resolver throws. All folders must keep `{ pkgs, packages, env, shellHook }:`.
- `with env;` presence must be consistent across all inputs.
- Shells merge by **name**: the output is the **union of shell names**; for each name,
  `buildInputs` tokens are **unioned, deduped, and sorted**.
- Inside a `mkShell` block, **only** `buildInputs = …;` and `inherit shellHook;` are allowed —
  any other field throws.
- `buildInputs` RHS is parsed as identifiers split on `++`; each must be an `env` category
  (`system`/`dev`/`main`/`lint`/`releaser`). No new category can be referenced without adding
  it to every merged `env.nix`.

Implication: a new `helm` shell can be added in `templates/helm/nix/shells.nix` only — the
merge unions it into the final `shells.nix` when Helm is enabled, composed strictly from
existing `env` categories. The `secret` folder's new `shells.nix` MUST use the exact 4-arg
signature and `with env;`.

### VE3 — `atomi/json-yaml` concat merge covers the CI/CD YAML and Taskfile

**Checked**: `cyan.yaml` resolver globs (this repo).

**CONFIRMED**: `.github/workflows/{ci,cd,release}.yaml`, `.github/dependabot.yml`,
`Taskfile.yaml`, `.coderabbit.yaml`, `atomi_release.yaml` are merged by `atomi/json-yaml`
with `arrayStrategy: concat`. Therefore:
- `Taskfile.yaml` `tasks.setup.cmds` arrays from `base` + `secret` **concatenate** in
  `(layer ASC, template ASC)` order — so a `setup` that contributes a meaningful command per
  layer merges cleanly; a no-op `echo "Completed"` is pure noise in the merged output.
- `ci.yaml` / `cd.yaml` `jobs` maps merge by key, so each folder adds its own job(s); the
  reusable workflow files (`⚡…`) are **not** in the resolver globs and are copied verbatim
  per folder (distinct filenames ⇒ no conflict).

### VE4 — Reference CI/CD scripts (per-commit build vs release republish)

**Checked**: `AtomiCloud/nitroso.tin` `scripts/ci/ci-docker.sh`, `scripts/ci/publish.sh`,
`.github/workflows/ci.yaml`.

**CONFIRMED**:
- `ci-docker.sh`: logs into the registry, derives `IMAGE_VERSION="<sha6>-<branch>"`, and
  `docker buildx build --push` with `commit`, `branch`, and (on the latest branch) `latest`
  tags. Caching is provided by the builder.
- `publish.sh`: derives the same `IMAGE_VERSION`, loops **all** `Chart.yaml` (`find`) setting
  `appVersion`, then `helm package … --version <ver> --app-version <IMAGE_VERSION>` and
  `helm push` each `.tgz` to the OCI registry — i.e. multi-chart, no cap.
- nitroso runs `ci-docker.sh` on a runner with the Namespace builder and `release.sh` via
  `nix develop .#releaser -c`. This spec reuses these shapes but splits cleanly into the
  CI (build) and CD (republish) halves the user requested.

### VE5 — `infisical run` without trailing `-- <cmd>` does not propagate secrets

**Checked**: existing `templates/secret/.claude/skills/infisical/SKILL.md` (in-repo, prior art).

**CONFIRMED**: the subprocess form `infisical run --env=dev -- <command>` is required;
the bare form does not export into the parent shell. Existing scripts already honor this;
no change required beyond ensuring `infisical` is on `PATH` in the dev shell.

## Requirements

### Functional Requirements

#### FR1 — Base Taskfile: `setup` + `lint` only

`templates/base/Taskfile.yaml` retains only `setup` and `lint`. Remove `test`, `build`,
`clean`. Docker (`docker:*`), Helm (`helm:*`), and Secret (`secret:*`) namespaces and the
`secret` top-level `setup` contribution are unchanged.

#### FR2 — Composable `setup`, no no-op script

- Delete the placeholder behavior `echo "Completed"`.
- `scripts/ci/setup.sh` is a **minimal extension point**: shebang + `set -euo pipefail` + a
  comment. It does **not** install pre-commit hooks — the Nix dev shell's `shellHook`
  (`checks.pre-commit-check.shellHook`) installs them automatically whenever the shell is
  entered, including in CI via `nix develop .#ci -c …`. Layers/projects add real setup steps here.
- `templates/base/Taskfile.yaml` `setup` runs `bash scripts/ci/setup.sh`.
- `templates/secret/Taskfile.yaml` `setup` keeps contributing `./scripts/local/secrets.sh`;
  under concat merge the merged `setup` becomes `[setup.sh, secrets.sh]` (base before secret).
- `scripts/ci/pre-commit.sh` still runs setup first, like before:
  `./scripts/ci/setup.sh` then `pre-commit run --all-files -v`.

#### FR3 — `secret` Nix dev env (infisical on PATH)

Add under `templates/secret/nix/` (only the two files needed — the nix resolver merges each
file independently, and the merged `default` shell already references the unioned `dev`, so no
`shells.nix`/`pre-commit.nix` duplication is required):
- `packages.nix` — signature `{ pkgs, pkgs-2605, pkgs-unstable, atomi }:`, inheriting
  `infisical` from `pkgs-2605` (resolver unions with base's set; safe to re-declare — makes the
  layer self-contained).
- `env.nix` — `{ pkgs, packages }:` with `with packages;` adding `infisical` to `dev`
  (and empty `system`/`main`/`lint`/`releaser` lists so the union merge is well-formed).

Result: when `secret` is enabled, the merged `nix/env.nix` lists `infisical` under `dev`, so
`nix develop` (default shell) exposes `infisical`. Verified by the regenerated `secret_only`
and `all_features` fixtures and a `grep -q 'infisical' nix/env.nix` validate.

#### FR4 — Docker CI (per commit): cached build + push, multi-tag, multi-image-capable

- `templates/docker/scripts/ci/docker.sh` (replaces `docker-build.sh`):
  - Validate env: `DOMAIN`, `GITHUB_REPO_REF`, `GITHUB_SHA`, `GITHUB_BRANCH`, `DOCKER_USER`,
    `DOCKER_PASSWORD`, `LATEST_BRANCH`, plus per-image `CI_DOCKER_IMAGE`, `CI_DOCKER_CONTEXT`,
    `CI_DOCKERFILE`, `CI_DOCKER_PLATFORM` (defaults for the single scaffold image).
  - `docker login`, derive `IMAGE_VERSION="<sha6>-<slug(branch)>"`, build refs
    `commit` / `branch` / `latest`, then `docker buildx build --push` with all applicable
    tags. The Namespace builder supplies the cache (fast rebuilds).
  - Default image params point at `infra/Dockerfile` for `let__platform__/let__service__`,
    but the design is **list-driven** (workflow matrix) so N images build per push with no cap.
- `templates/docker/Taskfile.yaml` (`docker:build`, `docker:push`, `docker:lint`) stays;
  `docker:build` may call `docker.sh` for local reproducibility.

#### FR5 — Docker CD (on release tag): retag commit image → semver, no rebuild

- `templates/docker/scripts/ci/docker-release.sh` (replaces `docker-push.sh`):
  - Validate env (registry creds + `GITHUB_REF_NAME`/release tag + commit ref inputs).
  - Re-tag the already-pushed commit image to the semver **without rebuilding** using
    `docker buildx imagetools create -t <image>:<semver> <image>:<commit>` (manifest-level,
    multi-arch safe). Repeat for every image (no cap).

#### FR6 — Helm CI (per commit): package + push at commit version, via Nix

- `templates/helm/scripts/ci/helm.sh` (replaces `helm-lint.sh` usage in CI build context):
  - Run under `nix develop .#helm` (helm/yq present; VE1/VE2).
  - Derive `IMAGE_VERSION="<sha6>-<slug(branch)>"`; for **all** `Chart.yaml` (`find`), set
    `appVersion`; `helm registry login`; `helm dependency build`; `helm package … --version
    v0.0.0-<IMAGE_VERSION> --app-version <IMAGE_VERSION> -d ./uploads`; `helm push` each `.tgz`.
  - `helm-lint.sh` is retained for the lint job (`pls helm:lint`).

#### FR7 — Helm CD (on release tag): repackage at semver, via Nix

- `templates/helm/scripts/ci/helm-release.sh` (replaces `helm-publish.sh`):
  - Run under `nix develop .#helm`.
  - Take the release semver (`$1` / `GITHUB_REF_NAME`); set `appVersion` to the corresponding
    commit `IMAGE_VERSION`; `helm package … --version <semver> --app-version <commit-ver>`;
    `helm push` each `.tgz`. Multi-chart, no cap. (Chosen approach: **repackage at semver**.)

#### FR8 — `.#helm` Nix shell

- `templates/helm/nix/shells.nix` adds a `helm` shell: `helm = pkgs.mkShell { buildInputs =
  system ++ lint; inherit shellHook; };` (composes `infrautils` + `infralint` + base `atomiutils`/lint;
  VE1/VE2). The `default` shell is unchanged.
- No new Docker Nix shell: Docker CI/CD run with the Namespace host Docker + buildx (FR4/FR5);
  `skopeo` remains available in the Docker `default` shell for local use.

#### FR9 — Workflows: thin Nix/nscloud runners, two triggers

- **Base** (`⚡reusable-precommit.yaml`, `⚡reusable-release.yaml`, `ci.yaml`, `release.yaml`,
  `cd.yaml`) unchanged except as required by FR2 (pre-commit script).
- **Docker**:
  - `ci.yaml` adds a `docker-ci` job (on `push`) running on a Namespace runner with the
    Namespace buildx builder, invoking `docker.sh` (matrix-capable for multi-image).
  - `cd.yaml` adds a `docker-cd` job (on `tags: v*.*.*`) running `docker-release.sh` (retag).
- **Helm**:
  - `ci.yaml` adds `helm-lint` + `helm-ci` jobs (on `push`) on a Namespace runner using
    `nix develop .#helm -c ./scripts/ci/{helm-lint,helm}.sh`.
  - `cd.yaml` adds a `helm-cd` job (on `tags: v*.*.*`) running
    `nix develop .#helm -c ./scripts/ci/helm-release.sh "${GITHUB_REF_NAME}"`.
- Cache tags follow the existing LPSM namespacing convention
  (`let__platform__-let__service__-*`) per `ci-cd.md`.
- Registry/credential env (`DOMAIN`, `GITHUB_REPO_REF`, `DOCKER_USER`, `DOCKER_PASSWORD`,
  `LATEST_BRANCH`, `GITHUB_SHA`, `GITHUB_BRANCH`) wired from GitHub `vars`/`secrets`.

#### FR10 — Skills & docs reflect the new scripts

Update to name the new scripts, the `nix develop .#<shell> -c` invocation, and the
CI(build)/CD(republish) split:
- `templates/docker/.claude/skills/docker-push/SKILL.md` + `docs/developer/standard/docker.md`
- `templates/helm/.claude/skills/helm-push/SKILL.md` + `docs/developer/standard/helm.md`
- `templates/base/docs/developer/standard/ci-cd.md` (document the two-trigger Docker/Helm model)
- `templates/secret/.claude/skills/infisical/SKILL.md` (note infisical now on the dev shell)

#### FR11 — Variable-syntax & shell-script discipline

- All `let__platform__` / `let__service__` placeholders preserved exactly; no stray
  `{{ }}` or residual markers (validate grep stays green).
- Every shell script starts with `#!/usr/bin/env bash` and `set -euo pipefail`
  (per `shell-scripts.md`); scripts pass `bash -n` and `shellcheck`.

### Non-Functional Requirements

- **NFR1 — Resolver safety**: every contributed `shells.nix` keeps the exact 4-arg signature
  and `with env;` (VE2); every `packages.nix` keeps `{ pkgs, pkgs-2605, pkgs-unstable, atomi }`.
- **NFR2 — Local reproducibility**: every CI/CD script is runnable locally via the same
  `nix develop .#<shell> -c …` (Helm) or host Docker (Docker) command used in CI.
- **NFR3 — No silent caps**: Docker (matrix) and Helm (`find`) handle N artifacts; nothing
  hard-codes exactly one.
- **NFR4 — Backwards-safe generation**: all 9 existing feature combinations still generate
  and pass `test.cyan.yaml`.

## Acceptance Criteria

### Functional checks
- AC1: `templates/base/Taskfile.yaml` has exactly `setup` + `lint`; no `test`/`build`/`clean`.
- AC2: No file contains the no-op `echo "Completed"`; `scripts/ci/setup.sh` installs hooks;
  merged `setup` (base+secret fixture) is `[setup.sh, secrets.sh]`.
- AC3: `secret`-enabled fixtures' merged `nix/env.nix` lists `infisical` under `dev`; merged
  `nix/shells.nix` parses and keeps the 4-arg signature.
- AC4: Docker fixtures contain `docker.sh` (CI, cached multi-tag) + `docker-release.sh`
  (CD retag); `ci.yaml` has a push-triggered docker job, `cd.yaml` a tag-triggered one.
- AC5: Helm fixtures contain `helm.sh`/`helm-release.sh`; CI/CD jobs invoke
  `nix develop .#helm -c …`; merged `shells.nix` contains a `helm` shell.
- AC6: All scripts pass `bash -n` and `shellcheck`; all YAML parses.

### Verification
- AC7: `cyanprint test template .` → **9/9 pass** with regenerated fixtures.
- AC8: A real `cyanprint try template` of an all-features project generates `nix/shells.nix`
  with `default` + `ci` + `helm` + `releaser` shells, and all `scripts/ci/*.sh` parse.

## Out of Scope

- The sibling `atomi/nix` (`ketone.nix-template`) flake — unchanged; this is template-side only.
- Actual deployment (kubectl apply / ArgoCD) on CD — only image retag + chart republish.
- Per-landscape Helm values files (already out of scope per `helm.md`).
- Changing the base `release.yaml` semantic-release flow beyond the `pre-commit.sh` tidy.
- Combining Docker + Helm into a single script (explicitly chosen: separate scripts).

## Open design notes (flagged for review)

- **Setup hook install**: `setup.sh` installing pre-commit hooks is the chosen "meaningful"
  replacement for the no-op; if the intent was purely to delete the placeholder and leave
  base `setup` empty, that is a one-line change.
- **Docker without Nix**: Docker CI/CD use host Docker + the Namespace builder (no `.#docker`
  shell), matching "docker = nscloud fast build, helm = nix". If Docker scripts should also run
  under Nix, add a `docker` shell (`system ++ dev`) and wrap the invocations.
- **Namespace buildx action pin**: workflows reference the Namespace setup/buildx actions for
  fast cached Docker builds; exact action versions to be confirmed against the org's pinned set.
