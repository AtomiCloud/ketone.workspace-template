# Helm

Helm conventions for Kubernetes chart packaging and deployment.

Both CI (every commit) and CD (release tag) publish through the `⚡reusable-helm.yaml`
workflow, which uses `AtomiCloud/actions.setup-nix` and runs
`nix develop .#ci -c ./scripts/ci/helm.sh <chart_path> [version]`. Publish more charts by
adding caller jobs (one per `chart_path`) — there is no cap.

## Structure

The root chart lives in `infra/root_chart/`:

- `Chart.yaml` — chart metadata
- `values.yaml` — default values
- `templates/` — Kubernetes manifest templates

## Linting

```bash
pls helm:lint
```

In CI, Helm linting runs through the pre-commit hook (not a separate job).

## Docs

```bash
pls helm:docs
```

## CI — package & push (every commit)

```bash
pls helm:build   # ./scripts/ci/helm.sh ./infra/root_chart
```

Publishes `v0.0.0-<sha6>-<branch>`, with `appVersion` set to the commit version.

## CD — release tag

On a `v*.*.*` tag the same script runs with the version arg
(`./scripts/ci/helm.sh ./infra/root_chart <version>`), packaging the chart at that semver.

## Out of Scope

Per-landscape values files (e.g. `values.<landscape>.yaml`) are deferred and not part of
the generated scaffold.
