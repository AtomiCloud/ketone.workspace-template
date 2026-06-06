---
name: helm-push
description: Helm chart lint and publish conventions
---

# Helm Push

Reference: [docs/developer/standard/helm.md](../../../docs/developer/standard/helm.md)

## Key Points

- Lint with `pls helm:lint` or `nix develop .#helm -c ./scripts/ci/helm-lint.sh`.
- Generate docs with `pls helm:docs`.
- **CI (per commit)**: `pls helm:build` or `nix develop .#helm -c ./scripts/ci/ci-helm.sh` —
  packages and pushes every chart to the OCI registry, versioned `v0.0.0-<sha6>-<branch>`.
- **CD (release tag)**: `pls helm:release` or
  `nix develop .#helm -c ./scripts/ci/cd-helm.sh <version>` — repackages every chart at the
  release semver, with `appVersion` pointing at the commit image.
- Helm scripts run under Nix (`.#helm` shell) so `helm`/`yq` are always available.
- The root chart lives in `infra/root_chart/`. All `Chart.yaml` files are published — there is
  no cap on the number of charts per push.
