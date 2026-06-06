# Docker

Docker conventions for containerized builds and deployments.

Images are built from `infra/Dockerfile`. Both CI (every commit) and CD (release tag)
publish through the `⚡reusable-docker.yaml` workflow, which uses
`AtomiCloud/actions.setup-docker` and runs `./scripts/ci/docker.sh [version]`. Publish more
images by adding caller jobs (one per `image_name`) — there is no cap.

## CI — build & push (every commit)

```bash
pls docker:build   # ./scripts/ci/docker.sh
```

Pushes `<sha6>-<branch>`, `<branch>`, and (on `main`) `latest`. The build is cached.

## CD — release tag

On a `v*.*.*` tag the same script runs with the version arg
(`./scripts/ci/docker.sh <version>`), adding the semver tag. Because the build is cached,
this is effectively a re-tag rather than a fresh build.

## Linting

```bash
pls docker:lint
```
