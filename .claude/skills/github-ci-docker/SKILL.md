# Claude Skill: GitHub CI/CD for Snoop Docker Images

**Purpose**: Guide the creation and maintenance of GitHub Actions workflows that build the Snoop Docker images and push them to Docker Hub.

---

## Overview

The Snoop repo contains two services that need Docker images built and pushed:

| Service | Dockerfile | Build Context | Docker Hub Image |
|---------|-----------|---------------|------------------|
| **backend** | `server/Dockerfile` | `server/` | `doublelayer/snoop-backend` |
| **frontend** | `client/Dockerfile` | `client/` | `doublelayer/snoop-frontend` |

**Docker Hub org**: `doublelayer`

---

## Required GitHub Secrets

These MUST be configured in the repo under **Settings > Secrets and variables > Actions**:

| Secret | Description |
|--------|-------------|
| `DOCKERHUB_USERNAME` | Docker Hub username with push access to the `doublelayer` org |
| `DOCKERHUB_TOKEN` | Docker Hub access token (not password) - generate at https://hub.docker.com/settings/security |

**Setting up Docker Hub access tokens**:
1. Log in to Docker Hub
2. Go to Account Settings > Security > New Access Token
3. Name: `snoop-github-actions`
4. Permissions: Read & Write
5. Copy the token and add it as `DOCKERHUB_TOKEN` in GitHub repo secrets

---

## Workflow: Build and Push

This is the primary workflow. It builds both images on push to `main` or on any tag, using multi-platform builds and GitHub Actions cache for fast rebuilds.

```yaml
# .github/workflows/docker-build-and-push.yml
name: docker-build-and-push

on:
  push:
    tags:
      - '*'
    branches:
      - 'main'

jobs:
  docker:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Set up QEMU
        uses: docker/setup-qemu-action@v3

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3
        with:
          install: true

      - name: Login to Docker Hub
        uses: docker/login-action@v3
        with:
          username: ${{ secrets.DOCKERHUB_USERNAME }}
          password: ${{ secrets.DOCKERHUB_TOKEN }}

      - name: Determine Docker tag
        id: vars
        run: |
          if [[ "${GITHUB_REF}" == refs/tags/* ]]; then
            echo "TAG=${GITHUB_REF#refs/tags/}" >> $GITHUB_OUTPUT
          else
            echo "TAG=latest" >> $GITHUB_OUTPUT
          fi

      # --- Backend Build ---
      - name: Build and Push Backend
        uses: docker/build-push-action@v5
        with:
          context: server
          file: ./server/Dockerfile
          push: true
          tags: |
            doublelayer/snoop-backend:${{ steps.vars.outputs.TAG }}
          cache-from: type=gha,scope=backend
          cache-to: type=gha,mode=max,scope=backend

      # --- Frontend Build ---
      - name: Build and Push Frontend
        uses: docker/build-push-action@v5
        with:
          context: client
          file: ./client/Dockerfile
          push: true
          tags: |
            doublelayer/snoop-frontend:${{ steps.vars.outputs.TAG }}
          cache-from: type=gha,scope=frontend
          cache-to: type=gha,mode=max,scope=frontend
```

### Tagging Strategy

| Trigger | Image Tag | Example |
|---------|-----------|---------|
| Push to `main` | `latest` | `doublelayer/snoop-backend:latest` |
| Push tag `v1.2.3` | `v1.2.3` | `doublelayer/snoop-backend:v1.2.3` |
| Push tag `1.0.0` | `1.0.0` | `doublelayer/snoop-backend:1.0.0` |

### How it Works

1. **Checkout** - clones the repo
2. **QEMU** - enables multi-architecture emulation (needed for cross-platform builds)
3. **Buildx** - Docker's extended builder with cache support
4. **Login** - authenticates to Docker Hub using repo secrets
5. **Tag detection** - if triggered by a git tag, uses that as the image tag; otherwise `latest`
6. **Build backend** - multi-stage build from `server/Dockerfile`, pushes to `doublelayer/snoop-backend`
7. **Build frontend** - multi-stage build from `client/Dockerfile`, pushes to `doublelayer/snoop-frontend`

Both builds use **GitHub Actions cache** (`type=gha`) scoped per service, so unchanged layers are reused across runs.

---

## Workflow: Build on Pull Request (No Push)

Use this as a CI check to verify images build successfully without pushing.

```yaml
# .github/workflows/docker-build-pr.yml
name: docker-build-pr

on:
  pull_request:
    branches:
      - 'main'
    paths:
      - 'server/**'
      - 'client/**'

jobs:
  build-check:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        include:
          - name: backend
            context: server
            dockerfile: ./server/Dockerfile
          - name: frontend
            context: client
            dockerfile: ./client/Dockerfile
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3

      - name: Build ${{ matrix.name }}
        uses: docker/build-push-action@v5
        with:
          context: ${{ matrix.context }}
          file: ${{ matrix.dockerfile }}
          push: false
          cache-from: type=gha,scope=${{ matrix.name }}
```

---

## Multi-Platform Builds

To build for both `linux/amd64` and `linux/arm64` (e.g., for Apple Silicon nodes), add the `platforms` key:

```yaml
      - name: Build and Push Backend
        uses: docker/build-push-action@v5
        with:
          context: server
          file: ./server/Dockerfile
          push: true
          platforms: linux/amd64,linux/arm64
          tags: |
            doublelayer/snoop-backend:${{ steps.vars.outputs.TAG }}
          cache-from: type=gha,scope=backend
          cache-to: type=gha,mode=max,scope=backend
```

**Note**: The backend installs Chromium via `apt-get`, so cross-platform builds work but take longer (~10-15 min vs ~3-5 min for amd64 only). Only enable if you need arm64.

---

## Advanced Tagging with docker/metadata-action

For richer tag strategies (semver, SHA, branch name), replace the manual tag step:

```yaml
      - name: Docker metadata
        id: meta
        uses: docker/metadata-action@v5
        with:
          images: doublelayer/snoop-backend
          tags: |
            type=ref,event=branch
            type=semver,pattern={{version}}
            type=semver,pattern={{major}}.{{minor}}
            type=sha,prefix=

      - name: Build and Push Backend
        uses: docker/build-push-action@v5
        with:
          context: server
          file: ./server/Dockerfile
          push: true
          tags: ${{ steps.meta.outputs.tags }}
          labels: ${{ steps.meta.outputs.labels }}
          cache-from: type=gha,scope=backend
          cache-to: type=gha,mode=max,scope=backend
```

This produces tags like:
- `doublelayer/snoop-backend:main` (branch push)
- `doublelayer/snoop-backend:1.2.3` (tag `v1.2.3`)
- `doublelayer/snoop-backend:1.2` (tag `v1.2.3`)
- `doublelayer/snoop-backend:abc1234` (commit SHA)

---

## Kubernetes Image References

After images are pushed, the Kubernetes manifests (see kubernetes-infrastructure skill) reference them:

```yaml
# Backend deployment
image: doublelayer/snoop-backend:latest   # or specific tag

# Frontend deployment
image: doublelayer/snoop-frontend:latest  # or specific tag
```

To deploy a specific version:
```bash
kubectl set image deployment/backend backend=doublelayer/snoop-backend:v1.2.3 -n snoop
kubectl set image deployment/frontend frontend=doublelayer/snoop-frontend:v1.2.3 -n snoop
```

---

## Adding a New Service

When adding a new Dockerized service to Snoop:

1. Create the `Dockerfile` in the service directory
2. Add a new build step to `docker-build-and-push.yml`:
   ```yaml
   - name: Build and Push <service-name>
     uses: docker/build-push-action@v5
     with:
       context: <service-dir>
       file: ./<service-dir>/Dockerfile
       push: true
       tags: |
         doublelayer/snoop-<service-name>:${{ steps.vars.outputs.TAG }}
       cache-from: type=gha,scope=<service-name>
       cache-to: type=gha,mode=max,scope=<service-name>
   ```
3. Add the same entry to the PR workflow matrix
4. Update the Kubernetes deployment to use `doublelayer/snoop-<service-name>`

---

## Directory Layout

```
.github/
└── workflows/
    ├── docker-build-and-push.yml   # Build + push on main/tags
    └── docker-build-pr.yml         # Build-only check on PRs
```

---

## Debugging Failed Builds

```bash
# Check workflow runs
gh run list --workflow=docker-build-and-push.yml

# View logs of a failed run
gh run view <run-id> --log-failed

# Check if secrets are set (won't show values)
gh secret list

# Test Docker build locally
docker build -t snoop-backend:test -f server/Dockerfile server/
docker build -t snoop-frontend:test -f client/Dockerfile client/
```

---

## How Claude Should Use This Skill

When working on CI/CD for Snoop:

- **Workflow files go in `.github/workflows/`** in the snoop repo root
- **Image names follow the pattern** `doublelayer/snoop-<service>`
- **Always use `docker/build-push-action@v5`** with Buildx and GHA cache
- **Never hardcode credentials** - always use `${{ secrets.DOCKERHUB_USERNAME }}` and `${{ secrets.DOCKERHUB_TOKEN }}`
- **PR workflows should build but NOT push** (`push: false`)
- **Use the existing tag detection pattern** - tags become image tags, main becomes `latest`
- **When adding services**, add build steps to both workflows
- **Reference the kubernetes-infrastructure skill** for how images are consumed in deployments
