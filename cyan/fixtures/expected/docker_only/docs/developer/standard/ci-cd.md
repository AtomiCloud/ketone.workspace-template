---
id: ci-cd
title: CI/CD Workflows
---

# CI/CD Workflows

This document describes the principles and patterns for CI/CD workflows in the workspace template.

## Architecture Overview

The CI/CD architecture is designed around three core principles:

1. **Local reproducibility** - All CI scripts must be runnable locally
2. **Separation of concerns** - GitHub Actions is just a task runner; logic lives in shell scripts
3. **Reusable patterns** - Abstract complexity into reusable workflows

## Three Workflow Types

| Workflow    | Trigger                          | Purpose                                    |
| ----------- | -------------------------------- | ------------------------------------------ |
| **CI**      | Every commit                     | Gates and checks that must pass regardless |
| **Release** | Merge to main (after CI success) | Semantic versioning, changelog, git tag    |
| **CD**      | New version (tag push)           | Deploy artifacts                           |

### CI Workflow

Runs on every commit to verify code quality. Example jobs might include:

- Pre-commit hooks (linting, formatting)
- Unit tests
- Integration tests
- Builds

### Release Workflow

Runs only after successful CI on main branch. Handles:

- Semantic versioning based on commit types
- Changelog generation
- Git tag creation
- GitHub release creation

### CD Workflow

Runs when a new version tag is pushed. Handles deployment operations.

## The Execution Pattern

```
Setup Nix -> Setup Caches -> nix develop -c ./scripts/ci/script.sh
```

**Why this pattern?**

- GitHub Actions is just a task runner
- Real logic lives in shell scripts
- Shell scripts run in Nix = **local reproducibility**
- You can run CI locally: `nix develop .#ci -c ./scripts/ci/script.sh`

### Example Execution

```yaml
- uses: actions/checkout@v6
- uses: AtomiCloud/actions.setup-nix@v2
- run: nix develop .#ci -c ./scripts/ci/script.sh
```

## Reusable Workflow Conventions

### Naming

- Reusable workflows are named with `⚡` emoji prefix
- Format: `⚡reusable-{purpose}.yaml`
- Examples: `⚡reusable-precommit.yaml`, `⚡reusable-test.yaml`

### Separation of Responsibilities

**Caller workflow is responsible for:**

- Defining the trigger
- Wiring inputs like `atomi_platform` and `atomi_service`
- Choosing which reusable workflow to invoke

**Reusable workflow is responsible for:**

- Checkout (`actions/checkout@v6`)
- Setup Nix (`AtomiCloud/actions.setup-nix@v2`)
- Any workflow-specific cache setup
- Running the shell script from `scripts/ci/`

### Example: Reusable Workflow Structure

```yaml
# .github/workflows/⚡reusable-precommit.yaml
name: Reusable Pre-Commit

on:
  workflow_call:
    inputs:
      atomi_platform:
        required: true
        type: string
      atomi_service:
        required: true
        type: string

jobs:
  precommit:
    runs-on: nscloud-ubuntu-22.04-amd64-32x64-with-cache
    steps:
      - uses: actions/checkout@v6
      - uses: AtomiCloud/actions.setup-nix@v2
      - run: nix develop .#ci -c ./scripts/ci/pre-commit.sh
```

<!-- prettier-ignore -->
```yaml
# .github/workflows/ci.yaml (caller)
name: CI

on:
  push:

jobs:
  precommit:
    uses: ./.github/workflows/⚡reusable-precommit.yaml
    secrets: inherit
    with:
      atomi_platform: test-platform
      atomi_service: test-service
```

## Infrastructure and Caching

### NS-Cloud Runners

Runners with Nix store caching for persistent build artifacts.

### LPSM-Based Cache Namespacing

Cache keys MUST use LPSM naming: `test-platform-test-service-*`

```yaml
nscloud-cache-tag-test-platform-test-service-nix-store-cache
```

This ensures:

- Caches are isolated per service
- No cache conflicts between services
- Predictable cache key patterns

### Required Inputs

All reusable workflows MUST accept:

- `atomi_platform` - Platform name for cache namespacing
- `atomi_service` - Service name for cache namespacing

## Local Reproducibility

All CI scripts MUST be runnable locally:

```bash
nix develop .#ci -c ./scripts/ci/script.sh
```

This allows developers to:

- Debug CI failures locally
- Run checks without pushing
- Verify changes before committing

## Directory Structure

```
.github/
└── workflows/
    ├── ci.yaml                    # Main CI workflow
    ├── release.yaml               # Release workflow
    ├── cd.yaml                    # Deploy workflow
    ├── ⚡reusable-precommit.yaml  # Reusable pre-commit
    ├── ⚡reusable-test.yaml       # Reusable test (example)
    └── ⚡reusable-build.yaml      # Reusable build (example)

scripts/
└── ci/
    ├── pre-commit.sh              # CI: pre-commit hooks
    ├── test-unit.sh               # CI: unit tests
    ├── test-int.sh                # CI: integration tests
    └── build.sh                   # CI: build
```

## Summary

| Aspect                    | Pattern                                                |
| ------------------------- | ------------------------------------------------------ |
| **Workflow types**        | CI (every commit), Release (main merge), CD (tag push) |
| **Execution**             | Nix -> Caches -> shell script                          |
| **Reusable workflows**    | Named with `⚡`, reusable workflow handles execution   |
| **Cache namespacing**     | `test-platform-test-service-nix-store-cache`       |
| **Local reproducibility** | `nix develop .#ci -c ./scripts/ci/script.sh`           |
