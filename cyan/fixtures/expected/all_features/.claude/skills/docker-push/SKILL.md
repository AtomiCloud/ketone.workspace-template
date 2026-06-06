---
name: docker-push
description: Docker build and push conventions
---

# Docker Push

Reference: [docs/developer/standard/docker.md](../../../docs/developer/standard/docker.md)

## Key Points

- Both CI (per commit) and CD (release tag) publish via the `⚡reusable-docker.yaml` workflow,
  which uses `AtomiCloud/actions.setup-docker` and runs `./scripts/ci/docker.sh [version]`.
- `./scripts/ci/docker.sh` with **no arg** = per-commit build: pushes `<sha6>-<branch>`,
  `<branch>`, and (on `main`) `latest`. With a **version arg** (release) it also pushes that
  semver tag. The build is cached, so the release build is effectively a re-tag.
- Local: `pls docker:build` (build & push) / `pls docker:lint`.
- The image is built from `infra/Dockerfile`. Publish more images by adding caller jobs that
  `uses: ./.github/workflows/⚡reusable-docker.yaml` (one per `image_name`) — no cap.
