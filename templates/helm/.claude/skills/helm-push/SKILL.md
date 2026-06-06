---
name: helm-push
description: Helm chart lint and publish conventions
---

# Helm Push

Reference: [docs/developer/standard/helm.md](../../../docs/developer/standard/helm.md)

## Key Points

- **Local** (Taskfile one-liners, never CI scripts):
  - `pls helm:template` — render the chart (`-- ...` to pass extra `helm template` args)
  - `pls helm:debug` — render with `--debug`
  - `pls helm:deps` — build chart dependencies
- Chart **lint** and **docs** are enforced by the pre-commit hooks (`pls lint`), not separate
  tasks — `helm lint` comes from `infrautils`, `helm-docs` from `infralint`.
- **CI/CD**: publishing runs through `⚡reusable-helm.yaml` (uses `AtomiCloud/actions.setup-nix`,
  runs in `nix develop .#cd`), which calls `./scripts/ci/helm.sh <chart_path> [version]`. No
  version = `v0.0.0-<sha6>-<branch>`; a version arg publishes that semver.
- Helm linting in CI runs through the pre-commit hook (not a separate job).
- Add more charts by adding caller jobs (one per `chart_path`) — no cap. Root chart:
  `infra/root_chart/`.
