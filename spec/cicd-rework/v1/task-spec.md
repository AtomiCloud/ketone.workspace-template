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

**Checked**: `AtomiCloud/nix-registry@v2` `binWrapper/{atomiutils,infrautils,infralint}.nix`
— specifically the binaries `cp`'d into each bundle's `$out/bin` (VE12).

**CONFIRMED** (by exposed `/bin`, not just `buildInputs`):
- `atomiutils` → `jq`, `yq-go` (`yq`) + general CLI utils.
- `infrautils` → `helm` (kubernetes-helm), `kubectl`, `k3d`, `kubectx`, `docker`, `tilt`,
  `opentofu`, gardenio, mirrord. **`skopeo` is in `buildInputs` but NOT `cp`'d → not exposed.**
- `infralint` → `hadolint`, `helm-docs`, `terraform-docs`, `tfsec`, `tflint`, `helmlint`.

Implication:
- Helm hooks: `helm lint` uses `${packages.infrautils}/bin/helm`; `helm-docs` uses
  `${packages.infralint}/bin/helm-docs` (the two were swapped before this change).
- `hadolint` is available via `infralint`; `skopeo` must be added explicitly (from `pkgs-2605`)
  because no bundle exposes it.
- `.#cd` = `system ++ main` resolves to `atomiutils + infrautils` when Helm is enabled, giving
  `helm` + `yq` — the toolset `helm.sh` needs.

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

#### FR4 — Docker publishing: one `docker.sh` via `⚡reusable-docker.yaml`

- `templates/docker/scripts/ci/docker.sh` (single script; `$1` = optional semver version):
  - Validate env (`DOMAIN`, `GITHUB_REPO_REF`, `GITHUB_SHA`, `GITHUB_BRANCH`, `DOCKER_USER`,
    `DOCKER_PASSWORD`, `LATEST_BRANCH`, `CI_DOCKER_IMAGE`/`CONTEXT`/`DOCKERFILE`/`PLATFORM`).
  - `docker login`, derive `IMAGE_VERSION="<sha6>-<branch>"`, then `docker buildx build --push`
    with `commit` + `branch` tags, `latest` (on `LATEST_BRANCH`), and the `semver` tag when a
    version arg is given. Build is cached, so the release run is effectively a re-tag.
  - Mirrors `AtomiCloud/sulfone.zinc` `scripts/ci/docker.sh` (VE4). `set -euo pipefail` at top;
    guard checks `[[ -n "${VAR:-}" ]] || { echo "❌ …"; exit 1; }`; conditional tags via
    substitution (no `if`/`else`, no `onExit` function); emoji-prefixed progress echos.
- `templates/docker/.github/workflows/⚡reusable-docker.yaml` (copied per-folder; **not**
  merged): `workflow_call` with inputs `image_name` (req), `dockerfile`/`context`/`platform`
  (defaulted), `version` (opt) — **no** `atomi_platform`/`atomi_service` (unused). Runs on
  `ubuntu-22.04`, uses `AtomiCloud/actions.setup-docker@v1`, runs
  `./scripts/ci/docker.sh ${{ inputs.version }}`.
- `templates/docker/nix/{packages,env}.nix` provide the atomi bundles **`infrautils`**
  (exposes `helm`/`kubectl`/`docker`/`tilt`/…) and **`infralint`** (exposes
  `hadolint`/`helm-docs`/`tflint`/…), plus **`skopeo`** from `pkgs-2605` — `skopeo` is in
  infrautils' `buildInputs` but not copied to its `/bin`, so it must be added explicitly (VE12).
  `hadolint` is now available via `infralint` but no Dockerfile-lint hook / `docker:lint` task is
  configured.

#### FR5 — Helm publishing: one `helm.sh` via `⚡reusable-helm.yaml`

- `templates/helm/scripts/ci/helm.sh` (single script; `$1` = `chart_path`, `$2` = optional
  semver version): sets `appVersion` on all `Chart.yaml`, `helm registry login`,
  `helm dependency build`, `helm package`, `helm push`. Version chosen by substitution
  (`HELM_VERSION="${version:-v0.0.0-${commit}}"`). Mirrors `sulfone.zinc` `scripts/ci/helm.sh`.
- `templates/helm/.github/workflows/⚡reusable-helm.yaml` (copied per-folder): `workflow_call`
  with inputs `chart_path` (req), `version` (opt) — **no** `atomi_platform`/`atomi_service`. Uses
  `AtomiCloud/actions.setup-nix@v2`, runs
  `nix develop .#cd -c ./scripts/ci/helm.sh "${{ inputs.chart_path }}" "${{ inputs.version }}"`.
- **No `.#helm` shell** — Helm publishing runs in the new `.#cd` shell (FR8). Helm linting in CI
  runs via the pre-commit hook (`a-helm-lint`), so there is no separate lint job/script.

#### FR8 — Dev shells: `ci` for CI, `cd` for CD

- `templates/base/nix/shells.nix` defines `default`, `ci` (`system ++ main ++ lint`), **`cd`
  (`system ++ main`)**, and `releaser`. `.#ci` runs CI checks (pre-commit); `.#cd` runs CD/
  publishing (Helm — `helm`/`yq` come from `infrautils`/`atomiutils` in `system`); `.#releaser`
  runs semantic-release. All keep the strict 4-arg signature (VE2).

#### FR6 — Caller workflows (`ci.yaml` / `cd.yaml`) `uses:` the reusables

- **Docker** `ci.yaml` adds a `docker` job (on `push`) → `⚡reusable-docker.yaml` with
  `image_name`/`dockerfile`; `cd.yaml` adds a `docker` job (on `tags: v*.*.*`) with the same
  plus `version: ${{ github.ref_name }}`.
- **Helm** `ci.yaml` adds a `helm` job → `⚡reusable-helm.yaml` with `chart_path`; `cd.yaml`
  adds a `helm` job with the same plus `version: ${{ github.ref_name }}`.
- Each `uses:` references the org actions only **indirectly** (through the reusable workflow) —
  no direct `namespacelabs/*` usage anywhere. Callers pass only the inputs the reusable needs
  (no `atomi_platform`/`atomi_service`).
- Publish more images/charts by adding caller jobs (one per `image_name` / `chart_path`) — no cap.

#### FR7 — Shared Nix store cache; reusable inputs only when required

- All Nix jobs (pre-commit, Helm, release) share one cache via
  `nscloud-cache-tag-atomi-nix-store-cache` (global, **not** per-service — saves cache space).
- `atomi_platform`/`atomi_service` inputs are removed from **all** reusable workflows and their
  callers (they were only used for per-service cache keys). `⚡reusable-precommit.yaml` /
  `⚡reusable-release.yaml` now take no inputs; their cache tag was already `atomi-nix-store-cache`.

#### FR8b — Taskfiles never call CI scripts

- `templates/docker/tasks/Taskfile.docker.yaml`: `build` / `run` / `dev` / `clean` as inline
  one-liners (`docker build|run|image rm`), with `{{.CLI_ARGS}}` so users pass flags/tags.
- `templates/helm/tasks/Taskfile.helm.yaml`: `template` / `debug` / `lint` / `docs` / `deps` as
  inline `helm …` one-liners.
- Neither calls `scripts/ci/*` — those belong to the CI/CD workflows only.

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
- AC4: Docker fixtures contain `scripts/ci/docker.sh` and `⚡reusable-docker.yaml`; merged
  `ci.yaml`/`cd.yaml` reference `reusable-docker` (CD passes `version: ${{ github.ref_name }}`).
- AC5: Helm fixtures contain `scripts/ci/helm.sh` and `⚡reusable-helm.yaml`; merged
  `ci.yaml`/`cd.yaml` reference `reusable-helm`; no `.#helm` shell, no `helm-lint` job.
- AC6: All scripts pass `bash -n`; all YAML parses; no direct `namespacelabs/*` usage.

### Verification
- AC7: `cyanprint test template .` → **9/9 pass** with regenerated fixtures.
- AC8: All Nix jobs use `nscloud-cache-tag-atomi-nix-store-cache`; the new `⚡reusable-helm.yaml`
  uses `AtomiCloud/actions.setup-nix@v2` + `.#ci`; `⚡reusable-docker.yaml` uses
  `AtomiCloud/actions.setup-docker@v1`.

## Out of Scope

- The sibling `atomi/nix` (`ketone.nix-template`) flake — unchanged; this is template-side only.
- Actual deployment (kubectl apply / ArgoCD) on CD — only image/chart publish.
- Per-landscape Helm values files (already out of scope per `helm.md`).
- Changing the base `release.yaml` semantic-release flow beyond the `pre-commit.sh` tidy.
- Combining Docker + Helm into a single script (explicitly chosen: separate `docker.sh`/`helm.sh`).

## Open design notes (flagged for review)

- **`setup.sh`**: a minimal extension point — pre-commit hooks are installed by the Nix
  `shellHook`, not by `setup.sh`. `pre-commit.sh` still runs `./scripts/ci/setup.sh` first.
- **Reusable workflows mirror `sulfone.zinc`**: `⚡reusable-docker.yaml` (uses
  `AtomiCloud/actions.setup-docker@v1`, `ubuntu-22.04`) and `⚡reusable-helm.yaml` (uses
  `AtomiCloud/actions.setup-nix@v2`, `.#ci`). No direct `namespacelabs/*` references.
- **Shared cache**: all Nix jobs use `nscloud-cache-tag-atomi-nix-store-cache` (global, not
  per-service); base pre-commit/release already use it and are unchanged.
- **Base `cd.yaml` placeholder**: left as-is (out of scope); merged `cd.yaml` still carries the
  base "Placeholder CD" job alongside the real docker/helm jobs.
- **`GITHUB_REF_SLUG`**: the reusable Docker/Helm jobs reference `${{ env.GITHUB_REF_SLUG }}`
  for the branch slug, matching `sulfone.zinc`; confirm `actions.setup-docker`/`setup-nix`
  provide it in the target org.
