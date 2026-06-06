---
name: docker-push
description: Docker build and push conventions
---

# Docker Push

Reference: [docs/developer/standard/docker.md](../../../docs/developer/standard/docker.md)

## Key Points

- **CI (per commit)**: `pls docker:build` or `./scripts/ci/ci-docker.sh` — builds and
  pushes the image with a cached buildx builder, tagged `<sha6>-<branch>`, `<branch>`, and
  (on the default branch) `latest`.
- **CD (release tag)**: `pls docker:release` or `./scripts/ci/cd-docker.sh <version>` —
  re-tags the existing commit image to the release version via `buildx imagetools` (no rebuild).
- Lint the Dockerfile with `pls docker:lint`.
- The image is built from `infra/Dockerfile`. Multiple images are supported via the workflow
  build matrix — there is no cap on the number of images per push.
- CI/CD run on Namespace (nscloud) runners for fast, cached builds.
