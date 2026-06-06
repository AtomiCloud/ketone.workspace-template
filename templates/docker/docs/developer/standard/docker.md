# Docker

Docker conventions for containerized builds and deployments. Images are built from
`infra/Dockerfile`.

## Local development

Local work uses Taskfile one-liners (these never call the CI scripts):

| Command            | What it does                                                              |
| ------------------ | ------------------------------------------------------------------------- |
| `pls docker:build` | Build the image locally as `<platform>-<service>:local`                   |
| `pls docker:run`   | Run the built image                                                       |
| `pls docker:dev`   | Build then run                                                            |
| `pls docker:clean` | Remove the local image                                                    |

Pass an optional tag **suffix** after `--`; it is appended to the `:local` tag:

```bash
pls docker:build            # -> <platform>-<service>:local
pls docker:build -- 1       # -> <platform>-<service>:local-1
pls docker:build -- hello   # -> <platform>-<service>:local-hello
```

`run`, `dev`, and `clean` take the same suffix so they act on the image you built.

## CI/CD release structure

Publishing is driven by the `⚡reusable-docker.yaml` reusable workflow, called from `ci.yaml`
(every commit) and `cd.yaml` (release tag):

1. The reusable workflow sets up the builder with `AtomiCloud/actions.setup-docker` — a
   Namespace (nscloud) backed buildx builder with managed layer caching, so you do **not**
   manage the cache yourself.
2. It runs `./scripts/ci/docker.sh [version]`:
   - **CI** (no version) → pushes `<sha6>-<branch>`, `<branch>`, and `latest` (on the default
     branch).
   - **CD** (version = the git tag) → also pushes the semver tag. The buildx cache is warm, so
     this is effectively a re-tag rather than a rebuild.
3. Images are pushed to `${DOMAIN}/${GITHUB_REPO_REF}/<image_name>` (defaults to
   `ghcr.io/<owner>/<repo>/<image_name>`).

### Adding more images

Each image is one caller job — there is **no cap**. Add a job to both `ci.yaml` and `cd.yaml`:

```yaml
jobs:
  api:
    uses: ./.github/workflows/⚡reusable-docker.yaml
    secrets: inherit
    with:
      image_name: api
      dockerfile: ./infra/api.Dockerfile
      version: ${{ github.ref_name }} # cd.yaml only
```

### Configuration (`⚡reusable-docker.yaml` inputs)

| Input        | Required | Default                     | Purpose                       |
| ------------ | -------- | --------------------------- | ----------------------------- |
| `image_name` | yes      | —                           | image repository name         |
| `dockerfile` | no       | `Dockerfile`                | path to the Dockerfile        |
| `context`    | no       | `.`                         | build context                 |
| `platform`   | no       | `linux/arm64,linux/amd64`   | target platforms              |
| `version`    | no       | —                           | release semver (set on CD)    |

## Linting

There is no Dockerfile lint step.
