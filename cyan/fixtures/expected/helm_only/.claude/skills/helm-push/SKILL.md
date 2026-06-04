---
name: helm-push
description: Helm chart lint and publish conventions
---

# Helm Push

Reference: [docs/developer/standard/helm.md](../../../docs/developer/standard/helm.md)

## Key Points

- Lint with `pls helm:lint` or `bash scripts/ci/helm-lint.sh`
- Generate docs with `pls helm:docs`
- Publish with `pls helm:push` or `bash scripts/ci/helm-publish.sh`
- The root chart lives in `infra/root_chart/`
