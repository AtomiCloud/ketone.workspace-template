# Helm

Helm conventions for Kubernetes chart packaging and deployment.

Helm CI/CD run under Nix (the `.#helm` dev shell provides `helm` and `yq`) on Namespace
(nscloud) runners. All `Chart.yaml` files are published — there is no cap on the number of
charts per push.

## Structure

The root chart lives in `infra/root_chart/`:

- `Chart.yaml` — chart metadata
- `values.yaml` — default values
- `templates/` — Kubernetes manifest templates

## Linting

```bash
pls helm:lint
```

## Docs

```bash
pls helm:docs
```

## CI — package & push (every commit)

```bash
pls helm:build   # nix develop .#helm -c ./scripts/ci/ci-helm.sh
```

Packages and pushes every chart to the OCI registry, versioned `v0.0.0-<sha6>-<branch>`,
with `appVersion` set to the commit image version.

## CD — repackage at release (release tag)

```bash
pls helm:release   # nix develop .#helm -c ./scripts/ci/cd-helm.sh <version>
```

Repackages every chart at the release semver, with `appVersion` pointing at the commit image.

## Out of Scope

Per-landscape values files (e.g. `values.<landscape>.yaml`) are deferred and not part of
the generated scaffold.
