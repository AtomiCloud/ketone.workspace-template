---
name: docker-push
description: Docker build and push conventions
---

# Docker Push

Reference: [docs/developer/standard/docker.md](../../../docs/developer/standard/docker.md)

## Key Points

- Build with `pls docker:build` or `bash scripts/ci/docker-build.sh`
- Push with `pls docker:push` or `bash scripts/ci/docker-push.sh`
- Lint Dockerfile with `pls docker:lint`
- Docker image uses `infra/Dockerfile`
