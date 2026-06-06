---
name: docker-push
description: Docker build and push conventions
---

# Docker Push

Reference: [docs/developer/standard/docker.md](../../../docs/developer/standard/docker.md)

## Key Points

- **Local** (Taskfile one-liners, never CI scripts):
  - `pls docker:build` — build as `<platform>-<service>:local` (`-- <suffix>` tags
    `:local-<suffix>`, e.g. `pls docker:build -- 1`)
  - `pls docker:run` — run the built image (same `-- <suffix>`)
  - `pls docker:dev` — build then run
  - `pls docker:clean` — remove the local image
- **CI/CD**: publishing runs through `⚡reusable-docker.yaml` (uses
  `AtomiCloud/actions.setup-docker`), which calls `./scripts/ci/docker.sh [version]`. No version
  = per-commit tags (`<sha6>-<branch>`, `<branch>`, `latest`); a version arg adds the semver
  (cached, so effectively a re-tag).
- Add more images by adding caller jobs that `uses: ⚡reusable-docker.yaml` (one per
  `image_name` / `dockerfile`) — no cap. The image is built from `infra/Dockerfile`.
- There is no Dockerfile lint step.
