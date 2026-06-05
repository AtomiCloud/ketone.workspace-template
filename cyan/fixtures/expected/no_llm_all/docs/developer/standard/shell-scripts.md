---
id: shell-scripts
title: Shell Script Conventions
---

# Shell Script Conventions

This document describes the conventions for shell scripts in the workspace template.

## Required Header

All scripts must start with:

```bash
#!/usr/bin/env bash
set -euo pipefail
```

**Explanation:**

- `#!/usr/bin/env bash` - Use bash via env for portability
- `set -e` - Exit immediately if a command exits with non-zero status (errexit)
- `set -u` - Treat unset variables as an error (nounset)
- `set -o pipefail` - Pipeline fails if any command in it fails

## Style Principles

### Linear and Procedural

- Avoid functions - keep scripts linear and readable
- Execute commands sequentially
- Use comments for section separation

### Portable and Safe

- Prefer simple, widely-supported Bash syntax; avoid obscure shell features
- Use `$(command)` for command substitution, not backticks
- Use `[[ ]]` for tests, not `[ ]`

### No Coloring

- Keep output simple and readable
- Avoid ANSI color codes

### Status Output

- Keep status output plain and minimal
- Use simple `echo` statements only when they improve clarity
- Prefer messages like `echo "Completed"` over decorative output

## Template

```bash
#!/usr/bin/env bash
set -euo pipefail

# commands here

echo "Completed"
```

## File Location

All shell scripts live in `scripts/` at the project root and are invoked via `pls <command>` defined in `Taskfile.yaml`.

```
scripts/
├── ci/
│   ├── setup.sh          # CI setup stub
│   ├── pre-commit.sh     # Pre-commit hooks
│   └── release.sh        # Release process
```

## Summary

| Aspect       | Pattern                                     |
| ------------ | ------------------------------------------- |
| **Header**   | `#!/usr/bin/env bash` + `set -euo pipefail` |
| **Style**    | Linear, portable Bash, no colors            |
| **Progress** | Minimal plain-text status output            |
| **Location** | `scripts/` directory                        |
