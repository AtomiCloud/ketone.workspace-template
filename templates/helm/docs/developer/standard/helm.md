# Helm

Helm conventions for Kubernetes chart packaging and deployment.

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

## Publishing

```bash
pls helm:push
```

## Out of Scope

Per-landscape values files (e.g. `values.<landscape>.yaml`) are deferred and not part of
the generated scaffold.
