# Helm

Helm conventions for Kubernetes chart packaging and deployment.

## Structure

The root chart lives in `infra/root_chart/`:

- `Chart.yaml` — chart metadata
- `values.yaml` — default values
- `templates/` — Kubernetes manifest templates

## Local development

Local work uses Taskfile one-liners (these never call the CI scripts):

| Command             | What it does                                                |
| ------------------- | ---------------------------------------------------------- |
| `pls helm:template` | Render the chart (pass extra `helm template` args via `--`) |
| `pls helm:debug`    | Render with `--debug`                                      |
| `pls helm:deps`     | Build chart dependencies                                   |

Chart **lint** and **docs** are not separate tasks — they run as pre-commit hooks (`pls lint`):
`helm lint` (from `infrautils`) and `helm-docs` (from `infralint`).

## CI/CD release structure

Publishing is driven by the `⚡reusable-helm.yaml` reusable workflow, called from `ci.yaml`
(every commit) and `cd.yaml` (release tag):

1. The reusable workflow uses `AtomiCloud/actions.setup-nix` and runs inside `nix develop .#cd`,
   so `helm`/`yq` come from the Nix store. The store is restored from the shared
   `nscloud-cache-tag-atomi-nix-store-cache` (one cache for all Nix jobs — no per-service keys),
   which is why Helm needs Nix while Docker does not.
2. It runs `./scripts/ci/helm.sh <chart_path> [version]`:
   - **CI** (no version) → publishes `v0.0.0-<sha6>-<branch>`, with `appVersion` set to the
     commit version.
   - **CD** (version = the git tag) → publishes that release semver.
3. Charts are pushed (OCI) to `${DOMAIN}/${GITHUB_REPO_REF}` (defaults to
   `ghcr.io/<owner>/<repo>`).

In CI, Helm linting runs through the pre-commit hook (not a separate job).

### Adding more charts

Each chart is one caller job — there is **no cap**. Add a job to both `ci.yaml` and `cd.yaml`:

```yaml
jobs:
  worker-chart:
    uses: ./.github/workflows/⚡reusable-helm.yaml
    secrets: inherit
    with:
      chart_path: ./infra/worker_chart
      version: ${{ github.ref_name }} # cd.yaml only
```

### Configuration (`⚡reusable-helm.yaml` inputs)

| Input        | Required | Default | Purpose                    |
| ------------ | -------- | ------- | -------------------------- |
| `chart_path` | yes      | —       | chart directory to publish |
| `version`    | no       | —       | release semver (set on CD) |

## Out of Scope

Per-landscape values files (e.g. `values.<landscape>.yaml`) are deferred and not part of
the generated scaffold.
