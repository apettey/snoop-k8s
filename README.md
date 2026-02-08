# snoop-k8s

Kubernetes deployment wrapper for [Snoop](https://github.com/code-by-fh/snoop) -- a real estate property search and notification platform that scrapes German real estate providers and alerts users via multiple channels.

This repo packages Snoop into a production-ready Kubernetes cluster with CI/CD, centralized logging, and infrastructure-as-code.

## Architecture

```
                          ┌─────────────────────────────────────────┐
                          │            snoop namespace              │
                          │                                        │
  :30000  ───────────────►│  ┌───────────┐      ┌──────────────┐   │
  Frontend                │  │  frontend  │─────►│   backend    │   │
                          │  │  (React)   │      │  (Express +  │   │
  :30100  ───────────────►│  └───────────┘      │  Puppeteer)  │   │
  Backend API             │                      └──────┬───────┘   │
                          │                             │           │
                          │                      ┌──────▼───────┐   │
  :30200  ───────────────►│                      │   mongodb    │   │
  MongoDB (admin)         │                      │  (mongo:6.0) │   │
                          │                      └──────────────┘   │
                          │                                        │
  :30300  ───────────────►│  ┌───────────┐   (dev only)            │
  MailHog UI              │  │  mailhog   │                        │
                          │  └───────────┘                        │
                          │                                        │
                          │  ┌─────────┐  ┌───────┐  ┌──────────┐ │
  :30500  ───────────────►│  │ grafana  │◄─│ loki  │◄─│  alloy   │ │
  Grafana                 │  └─────────┘  └───────┘  └──────────┘ │
                          │       Logging Stack                    │
                          └─────────────────────────────────────────┘
```

## What's in this repo

| Path | Description |
|------|-------------|
| `snoop/` | Application source code (git submodule) |
| `infra/k8s/` | Kubernetes manifests for all services |
| `infra/k8s/logging/` | Loki + Alloy + Grafana logging stack |
| `.github/workflows/` | CI/CD pipelines for Docker image builds |
| `.claude/skills/` | Claude Code skill definitions for AI-assisted development |
| `Makefile` | One-command setup, deploy, and management targets |

## Prerequisites

- [minikube](https://minikube.sigs.k8s.io/docs/start/)
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- [Docker](https://docs.docker.com/get-docker/)
- [envsubst](https://www.gnu.org/software/gettext/manual/html_node/envsubst-Invocation.html) (part of `gettext`, pre-installed on most systems)

## Quick Start

### 1. Clone with submodules

```bash
git clone --recurse-submodules https://github.com/<your-org>/snoop-k8s.git
cd snoop-k8s
```

### 2. Start minikube

```bash
minikube start \
  --cpus=4 \
  --memory=8192 \
  --disk-size=50g \
  --driver=docker \
  --addons=metrics-server,storage-provisioner
```

### 3. Set environment variables

```bash
export JWT_SECRET="your-jwt-secret"
export TRACKING_SECRET_KEY="your-tracking-key"
export MAPBOX_ACCESS_TOKEN="your-mapbox-token"
export WHATS_APP_API_URL=""
export WHATS_APP_API_TOKEN=""
export SMTP_USER=""
export SMTP_PASS=""
export GRAFANA_ADMIN_PASSWORD="admin"
```

### 4. Deploy everything

```bash
make k8s-all
```

This runs setup, creates secrets, deploys the application stack, and deploys the logging stack in one command.

### 5. Access the services

```bash
# Get your minikube IP
minikube ip

# Or open directly
minikube service frontend -n snoop --url   # Web UI
minikube service backend -n snoop --url    # API
minikube service grafana -n snoop --url    # Log dashboard
```

| Service | NodePort | URL |
|---------|----------|-----|
| Frontend | 30000 | `http://<minikube-ip>:30000` |
| Backend API | 30100 | `http://<minikube-ip>:30100` |
| MongoDB | 30200 | `mongodb://<minikube-ip>:30200` |
| MailHog UI | 30300 | `http://<minikube-ip>:30300` |
| Grafana | 30500 | `http://<minikube-ip>:30500` |

Default Snoop admin credentials: `admin` / `Password123!` (change on first login).

## Services

### Application

- **Backend** -- Node.js Express API with PM2, Puppeteer web scrapers for 14+ German real estate providers, cron-based job scheduling, and multi-channel notifications (Slack, Telegram, Email, WhatsApp, webhooks)
- **Frontend** -- React 18 SPA with TypeScript, TailwindCSS, Mapbox map integration, and real-time WebSocket updates
- **MongoDB** -- Primary data store for users, search jobs, and property listings
- **MailHog** -- Development-only SMTP server with web UI for testing email notifications

### Logging

- **Loki** -- Log aggregation engine (monolithic mode, 7-day retention, filesystem storage)
- **Alloy** -- Grafana's log collector running as a DaemonSet, automatically scrapes all pod logs in the `snoop` namespace
- **Grafana** -- Pre-configured with Loki datasource and a "Snoop Logs" dashboard showing log volume, error rates, and live log streams with per-service filtering

## CI/CD

Docker images are built and pushed to Docker Hub via GitHub Actions:

| Image | Trigger | Tags |
|-------|---------|------|
| `petdog/snoop-backend` | Push to `main` or git tag | `latest` or tag name |
| `petdog/snoop-frontend` | Push to `main` or git tag | `latest` or tag name |

### Required GitHub Secrets

| Secret | Description |
|--------|-------------|
| `DOCKERHUB_USERNAME` | Docker Hub username with push access |
| `DOCKERHUB_TOKEN` | Docker Hub access token |

Pull requests that touch `snoop/server/` or `snoop/client/` trigger a build-only check (no push).

## Makefile Reference

```
make help                  Show all available targets

make k8s-setup             Create namespace and ConfigMaps
make k8s-secrets           Create secrets from environment variables
make k8s-deploy            Deploy application services (MongoDB, backend, frontend, mailhog)
make k8s-logging-deploy    Deploy logging stack (Loki, Alloy, Grafana)
make k8s-all               Deploy everything in one shot

make k8s-status            Show status of all pods, services, and PVCs
make k8s-logging-status    Show logging stack status
make k8s-logs SERVICE=x    Tail logs for a service (e.g., SERVICE=backend)
make k8s-shell SERVICE=x   Shell into a running service

make k8s-clean             Delete the entire snoop namespace
make k8s-logging-clean     Remove only the logging stack
```

## Project Structure

```
snoop-k8s/
├── README.md
├── Makefile
├── snoop/                              # Application source (git submodule)
│   ├── server/                         # Backend (Node.js + Express)
│   │   └── Dockerfile
│   └── client/                         # Frontend (React + TypeScript)
│       └── Dockerfile
├── .github/
│   └── workflows/
│       ├── docker-build-and-push.yml   # Build + push on main/tags
│       └── docker-build-pr.yml         # Build-only check on PRs
└── infra/
    └── k8s/
        ├── namespace.yaml
        ├── config/
        │   ├── backend-configmap.yaml
        │   └── frontend-configmap.yaml
        ├── secrets/
        │   ├── backend-secret.yaml.template
        │   └── frontend-secret.yaml.template
        ├── services/
        │   ├── backend-service.yaml
        │   ├── frontend-service.yaml
        │   ├── mongodb-service.yaml
        │   └── mailhog-service.yaml
        ├── deployments/
        │   ├── backend-deployment.yaml
        │   ├── frontend-deployment.yaml
        │   └── mailhog-deployment.yaml
        ├── statefulsets/
        │   └── mongodb-statefulset.yaml
        └── logging/
            ├── alloy-rbac.yaml
            ├── alloy-configmap.yaml
            ├── alloy-daemonset.yaml
            ├── loki-configmap.yaml
            ├── loki-statefulset.yaml
            ├── loki-service.yaml
            ├── grafana-datasources-configmap.yaml
            ├── grafana-dashboard-provisioner-configmap.yaml
            ├── grafana-dashboard-configmap.yaml
            ├── grafana-deployment.yaml
            ├── grafana-service.yaml
            └── grafana-secret.yaml.template
```

## Deploying a Specific Version

```bash
# Tag and push to trigger a versioned build
git tag v1.0.0
git push origin v1.0.0

# Then update the cluster
kubectl set image deployment/backend backend=petdog/snoop-backend:v1.0.0 -n snoop
kubectl set image deployment/frontend frontend=petdog/snoop-frontend:v1.0.0 -n snoop
```

## License

See the [Snoop repository](https://github.com/code-by-fh/snoop) for application licensing.
