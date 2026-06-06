# Docker

Docker conventions for containerized builds and deployments.

The image is built from `infra/Dockerfile`. CI/CD run on Namespace (nscloud) runners with a
cached buildx builder for fast builds. Multiple images are supported via the workflow build
matrix — there is no cap on the number of images built per push.

## CI — build & push (every commit)

```bash
pls docker:build   # ./scripts/ci/ci-docker.sh
```

Builds and pushes the image, tagged `<sha6>-<branch>`, `<branch>`, and (on the default
branch) `latest`. The buildx builder provides the cache, so rebuilds are fast.

## CD — re-tag to release (release tag)

```bash
pls docker:release   # ./scripts/ci/cd-docker.sh <version>
```

Re-tags the already-built commit image to the release version with `buildx imagetools`
(manifest-level, multi-arch safe) — no rebuild.

## Linting

```bash
pls docker:lint
```
