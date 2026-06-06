---
name: helm-push
description: Helm chart lint and publish conventions
---

# Helm Push

Reference: [docs/developer/standard/helm.md](../../../docs/developer/standard/helm.md)

## Key Points

- Both CI (per commit) and CD (release tag) publish via the `⚡reusable-helm.yaml` workflow,
  which uses `AtomiCloud/actions.setup-nix` and runs
  `nix develop .#ci -c ./scripts/ci/helm.sh <chart_path> [version]`.
- `./scripts/ci/helm.sh <chart_path>` with **no version** = per-commit publish
  (`v0.0.0-<sha6>-<branch>`). With a **version arg** (release) it packages at that semver.
  Both set `appVersion` from the same commit/version tag.
- Local: `pls helm:build`, `pls helm:lint`, `pls helm:docs`.
- Helm linting in CI runs through the pre-commit hook (not a separate job).
- The root chart lives in `infra/root_chart/`. Publish more charts by adding caller jobs
  (one per `chart_path`) — no cap.
