---
name: infisical
description: Infisical secret management conventions
---

# Infisical

Reference: [docs/developer/standard/infisical.md](../../../docs/developer/standard/infisical.md)

## Key Points

- Authenticate and fetch with `pls setup` or `bash scripts/local/secrets.sh`
- Always use the subprocess form: `infisical run --env=dev -- <command>` (with trailing `-- `)
- The bare form `infisical run --env=dev` does NOT propagate secrets to the parent shell
- Scan for hardcoded secrets with `infisical scan`
- Fetch secrets with `pls secret:fetch`
