# Claude Skill: Kubernetes Infrastructure for Snoop

**Purpose**: Guide all Kubernetes infrastructure definitions, deployments, and configuration for the Snoop real estate search platform.

---

## System Overview

Snoop is a real estate property search and notification platform. It scrapes German real estate providers, detects duplicates, and notifies users via multiple channels (Slack, Telegram, Email, etc.).

### Services

| Service | Type | Image | Container Port | Description |
|---------|------|-------|----------------|-------------|
| **backend** | Deployment | snoop/backend | 5000 | Node.js API (Express + PM2), Puppeteer scrapers, cron jobs |
| **frontend** | Deployment | snoop/frontend | 3000 | React SPA served via `serve` |
| **mongodb** | StatefulSet | mongo:6.0 | 27017 | Primary data store |
| **mailhog** | Deployment | mailhog/mailhog | 1025 (SMTP), 8025 (UI) | Dev-only email testing |

---

## Core Principles

### 1. Everything Runs on Kubernetes

**Rule**: All production infrastructure MUST be defined as Kubernetes resources.

- All application services, stateful services, configuration, networking, and storage
- Don't use docker-compose in production
- Don't manage services outside of Kubernetes

---

## Namespace: `snoop`

**Rule**: All Snoop resources MUST be deployed to the `snoop` namespace.

```yaml
# infra/k8s/namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: snoop
  labels:
    app.kubernetes.io/name: snoop
    app.kubernetes.io/part-of: snoop-platform
```

**Resource Naming Convention**:
```
Format: <service-name>-<resource-type>

Examples:
- backend-deployment
- backend-service
- backend-configmap
- mongodb-statefulset
- mongodb-pvc
```

---

## Development Environment: Minikube

### Local Development Setup

```bash
# Start minikube with sufficient resources
minikube start \
  --cpus=4 \
  --memory=8192 \
  --disk-size=50g \
  --driver=docker \
  --addons=metrics-server,storage-provisioner

# Create and set snoop namespace
kubectl apply -f infra/k8s/namespace.yaml
kubectl config set-context --current --namespace=snoop
```

### Storage

- Minikube includes automatic PV provisioning via `storage-provisioner` addon
- Uses `hostPath` storage class by default
- PVCs automatically bound to dynamically provisioned PVs

---

## NodePort Assignments

**Rule**: All services requiring external access MUST use NodePort type with ports in 30000-32767 range.

| Service | NodePort | Internal Port | Purpose |
|---------|----------|---------------|---------|
| **frontend** | 30000 | 3000 | Web UI |
| **backend** | 30100 | 5000 | REST API + WebSocket |
| **mongodb** | 30200 | 27017 | Database (admin access only) |
| **mailhog UI** | 30300 | 8025 | Dev email testing UI |

**Accessing Services**:
```bash
# Get minikube IP
minikube ip

# Access frontend
curl http://$(minikube ip):30000

# Or use minikube service command
minikube service frontend -n snoop --url
```

**Port Conflict Checking**:
```bash
minikube service list -n snoop
```

---

## Service Definitions

### Frontend Service

```yaml
# infra/k8s/services/frontend-service.yaml
apiVersion: v1
kind: Service
metadata:
  name: frontend
  namespace: snoop
  labels:
    app: frontend
    tier: frontend
spec:
  type: NodePort
  selector:
    app: frontend
  ports:
    - name: http
      protocol: TCP
      port: 3000
      targetPort: 3000
      nodePort: 30000
```

### Backend Service

```yaml
# infra/k8s/services/backend-service.yaml
apiVersion: v1
kind: Service
metadata:
  name: backend
  namespace: snoop
  labels:
    app: backend
    tier: backend
spec:
  type: NodePort
  selector:
    app: backend
  ports:
    - name: http
      protocol: TCP
      port: 5000
      targetPort: 5000
      nodePort: 30100
```

### MongoDB Service

```yaml
# infra/k8s/services/mongodb-service.yaml
apiVersion: v1
kind: Service
metadata:
  name: mongodb
  namespace: snoop
  labels:
    app: mongodb
    tier: data
spec:
  type: NodePort
  selector:
    app: mongodb
  ports:
    - name: mongo
      protocol: TCP
      port: 27017
      targetPort: 27017
      nodePort: 30200
```

---

## Configuration Management

### Backend ConfigMap

```yaml
# infra/k8s/config/backend-configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: backend-config
  namespace: snoop
  labels:
    app: backend
data:
  NODE_ENV: "production"
  LOG_LEVEL: "info"
  MONGO_DB_DEBUG: "false"
  IS_DEMO: "false"
  SELF_REGISTRATION_ENABLED: "false"
  TRACKING_ENABLED: "true"

  # Service discovery (Kubernetes DNS)
  MONGODB_URI: "mongodb://mongodb.snoop.svc.cluster.local:27017/snoop"
  SNOOP_FRONTEND_BASE_URL: "http://frontend.snoop.svc.cluster.local:3000"
  API_BASE_URL: "http://backend.snoop.svc.cluster.local:5000/api"

  # SMTP (dev: mailhog, prod: real provider)
  SMTP_HOST: "mailhog.snoop.svc.cluster.local"
  SMTP_PORT: "1025"

  # Puppeteer
  PUPPETEER_SKIP_CHROMIUM_DOWNLOAD: "true"
  PUPPETEER_EXECUTABLE_PATH: "/usr/bin/chromium"
```

### Frontend ConfigMap

```yaml
# infra/k8s/config/frontend-configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: frontend-config
  namespace: snoop
  labels:
    app: frontend
data:
  APP_PREFIX: "SNOOP_"
  ASSET_DIR: "/dist"
  SNOOP_IS_DEMO: "false"
  SNOOP_TRACKING_ENABLED: "false"

  # These should point to external URLs users access from browser
  # Override with actual minikube IP or ingress URL
  SNOOP_API_URL: "http://localhost:30100/api"
  SNOOP_WS_URL: "http://localhost:30100"
```

### Backend Secret

```yaml
# infra/k8s/secrets/backend-secret.yaml.template
apiVersion: v1
kind: Secret
metadata:
  name: backend-secret
  namespace: snoop
  labels:
    app: backend
type: Opaque
stringData:
  JWT_SECRET: ${JWT_SECRET}
  TRACKING_SECRET_KEY: ${TRACKING_SECRET_KEY}
  MAPBOX_ACCESS_TOKEN: ${MAPBOX_ACCESS_TOKEN}
  WHATS_APP_API_URL: ${WHATS_APP_API_URL}
  WHATS_APP_API_TOKEN: ${WHATS_APP_API_TOKEN}
  SMTP_USER: ${SMTP_USER}
  SMTP_PASS: ${SMTP_PASS}
```

### Frontend Secret

```yaml
# infra/k8s/secrets/frontend-secret.yaml.template
apiVersion: v1
kind: Secret
metadata:
  name: frontend-secret
  namespace: snoop
  labels:
    app: frontend
type: Opaque
stringData:
  SNOOP_MAPBOX_ACCESS_TOKEN: ${MAPBOX_ACCESS_TOKEN}
```

**IMPORTANT**: Secrets MUST NOT be committed to git in plain text.

```bash
# Create secrets from env vars
envsubst < infra/k8s/secrets/backend-secret.yaml.template | kubectl apply -f -

# Or create directly
kubectl create secret generic backend-secret \
  --from-literal=JWT_SECRET=your-secret \
  --from-literal=TRACKING_SECRET_KEY=your-key \
  -n snoop
```

---

## Persistent Storage

### MongoDB PVC

```yaml
# infra/k8s/storage/mongodb-pvc.yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: mongodb-pvc
  namespace: snoop
  labels:
    app: mongodb
    tier: data
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 20Gi
  storageClassName: standard
```

---

## Deployments & StatefulSets

### Backend Deployment

```yaml
# infra/k8s/deployments/backend-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: backend
  namespace: snoop
  labels:
    app: backend
    tier: backend
spec:
  replicas: 1
  selector:
    matchLabels:
      app: backend
  template:
    metadata:
      labels:
        app: backend
        tier: backend
    spec:
      containers:
        - name: backend
          image: petdog/snoop-backend:latest
          ports:
            - containerPort: 5000
          envFrom:
            - configMapRef:
                name: backend-config
            - secretRef:
                name: backend-secret
          resources:
            requests:
              cpu: 200m
              memory: 512Mi
            limits:
              cpu: 1000m
              memory: 2Gi
          livenessProbe:
            httpGet:
              path: /health
              port: 5000
            initialDelaySeconds: 30
            periodSeconds: 10
            timeoutSeconds: 5
            failureThreshold: 3
          readinessProbe:
            httpGet:
              path: /health
              port: 5000
            initialDelaySeconds: 10
            periodSeconds: 5
            timeoutSeconds: 3
            failureThreshold: 3
```

**Note**: The backend runs Puppeteer with Chromium for web scraping. The Docker image installs Chromium in the build stage. Resource limits should account for Chromium memory usage (hence the 2Gi limit).

### Frontend Deployment

```yaml
# infra/k8s/deployments/frontend-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: frontend
  namespace: snoop
  labels:
    app: frontend
    tier: frontend
spec:
  replicas: 1
  selector:
    matchLabels:
      app: frontend
  template:
    metadata:
      labels:
        app: frontend
        tier: frontend
    spec:
      containers:
        - name: frontend
          image: petdog/snoop-frontend:latest
          ports:
            - containerPort: 3000
          envFrom:
            - configMapRef:
                name: frontend-config
            - secretRef:
                name: frontend-secret
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 200m
              memory: 256Mi
```

### MongoDB StatefulSet

```yaml
# infra/k8s/statefulsets/mongodb-statefulset.yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: mongodb
  namespace: snoop
  labels:
    app: mongodb
    tier: data
spec:
  serviceName: mongodb
  replicas: 1
  selector:
    matchLabels:
      app: mongodb
  template:
    metadata:
      labels:
        app: mongodb
        tier: data
    spec:
      containers:
        - name: mongodb
          image: mongo:6.0
          ports:
            - containerPort: 27017
              name: mongo
          volumeMounts:
            - name: data
              mountPath: /data/db
          resources:
            requests:
              cpu: 200m
              memory: 512Mi
            limits:
              cpu: 1000m
              memory: 2Gi
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes: ["ReadWriteOnce"]
        resources:
          requests:
            storage: 20Gi
```

### MailHog Deployment (Dev Only)

```yaml
# infra/k8s/deployments/mailhog-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mailhog
  namespace: snoop
  labels:
    app: mailhog
    tier: dev
spec:
  replicas: 1
  selector:
    matchLabels:
      app: mailhog
  template:
    metadata:
      labels:
        app: mailhog
        tier: dev
    spec:
      containers:
        - name: mailhog
          image: mailhog/mailhog
          ports:
            - containerPort: 1025
              name: smtp
            - containerPort: 8025
              name: http
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 200m
              memory: 256Mi
```

---

## Resource Allocations

| Service | CPU Request | CPU Limit | Memory Request | Memory Limit | Notes |
|---------|-------------|-----------|----------------|--------------|-------|
| **backend** | 200m | 1000m | 512Mi | 2Gi | Puppeteer/Chromium needs memory |
| **frontend** | 50m | 200m | 64Mi | 256Mi | Static file serving |
| **mongodb** | 200m | 1000m | 512Mi | 2Gi | Depends on dataset size |
| **mailhog** | 50m | 200m | 64Mi | 256Mi | Dev only |

---

## Service Discovery

**Rule**: Use Kubernetes DNS for all internal service communication.

| From | To | DNS Name | Port |
|------|----|----------|------|
| backend | mongodb | `mongodb:27017` | 27017 |
| backend | mailhog | `mailhog:1025` | 1025 |
| frontend | backend | `backend:5000` | 5000 |

**Note**: Frontend runs in the browser, so it cannot use K8s DNS directly. The frontend ConfigMap should point `SNOOP_API_URL` and `SNOOP_WS_URL` to the backend's externally accessible URL (NodePort or Ingress).

---

## Directory Layout

```
infra/k8s/
├── namespace.yaml
├── config/
│   ├── backend-configmap.yaml
│   └── frontend-configmap.yaml
├── secrets/
│   ├── backend-secret.yaml.template
│   └── frontend-secret.yaml.template
├── storage/
│   └── mongodb-pvc.yaml
├── services/
│   ├── backend-service.yaml
│   ├── frontend-service.yaml
│   ├── mongodb-service.yaml
│   └── mailhog-service.yaml
├── deployments/
│   ├── backend-deployment.yaml
│   ├── frontend-deployment.yaml
│   └── mailhog-deployment.yaml
└── statefulsets/
    └── mongodb-statefulset.yaml
```

---

## Deployment Commands

### Initial Setup

```bash
# 1. Create namespace
kubectl apply -f infra/k8s/namespace.yaml

# 2. Create PVCs
kubectl apply -f infra/k8s/storage/

# 3. Create ConfigMaps
kubectl apply -f infra/k8s/config/

# 4. Create Secrets
envsubst < infra/k8s/secrets/backend-secret.yaml.template | kubectl apply -f -
envsubst < infra/k8s/secrets/frontend-secret.yaml.template | kubectl apply -f -

# 5. Deploy MongoDB (wait for ready)
kubectl apply -f infra/k8s/statefulsets/
kubectl wait --for=condition=ready pod -l app=mongodb -n snoop --timeout=300s

# 6. Create Services
kubectl apply -f infra/k8s/services/

# 7. Deploy Applications
kubectl apply -f infra/k8s/deployments/
```

### Makefile Integration

```makefile
.PHONY: k8s-setup k8s-deploy k8s-clean k8s-status k8s-logs

k8s-setup: ## Setup namespace, storage, and config
	kubectl apply -f infra/k8s/namespace.yaml
	kubectl apply -f infra/k8s/storage/
	kubectl apply -f infra/k8s/config/

k8s-secrets: ## Create secrets from environment variables
	@test -n "$$JWT_SECRET" || (echo "Error: JWT_SECRET not set" && exit 1)
	envsubst < infra/k8s/secrets/backend-secret.yaml.template | kubectl apply -f -
	envsubst < infra/k8s/secrets/frontend-secret.yaml.template | kubectl apply -f -

k8s-deploy: ## Deploy all services
	kubectl apply -f infra/k8s/statefulsets/
	kubectl wait --for=condition=ready pod -l tier=data -n snoop --timeout=300s
	kubectl apply -f infra/k8s/services/
	kubectl apply -f infra/k8s/deployments/

k8s-status: ## Show status of all resources
	kubectl get all -n snoop
	kubectl get pvc -n snoop
	kubectl get configmap -n snoop
	kubectl get secret -n snoop

k8s-clean: ## Delete all Kubernetes resources
	kubectl delete namespace snoop

k8s-logs: ## Show logs for a service (usage: make k8s-logs SERVICE=backend)
	kubectl logs -f -l app=$(SERVICE) -n snoop

k8s-shell: ## Shell into a service (usage: make k8s-shell SERVICE=backend)
	kubectl exec -it deployment/$(SERVICE) -n snoop -- /bin/sh
```

---

## Health Checks

**Backend** exposes `GET /health` on port 5000 (confirmed in Dockerfile healthcheck).

```yaml
livenessProbe:
  httpGet:
    path: /health
    port: 5000
  initialDelaySeconds: 30
  periodSeconds: 10
readinessProbe:
  httpGet:
    path: /health
    port: 5000
  initialDelaySeconds: 10
  periodSeconds: 5
```

**Frontend** serves static files, so a TCP probe is sufficient:

```yaml
readinessProbe:
  tcpSocket:
    port: 3000
  initialDelaySeconds: 5
  periodSeconds: 5
```

**MongoDB** uses a TCP probe on 27017.

---

## Adding New Services

When adding a new service to Snoop, follow this checklist:

1. Create a ConfigMap in `infra/k8s/config/<name>-configmap.yaml`
2. Create a Secret template in `infra/k8s/secrets/<name>-secret.yaml.template` (if needed)
3. Create a PVC in `infra/k8s/storage/<name>-pvc.yaml` (if stateful)
4. Create a Service in `infra/k8s/services/<name>-service.yaml`
5. Create a Deployment or StatefulSet in the appropriate directory
6. Assign a NodePort from the next available slot in the relevant range
7. Update this skill file with the new service details
8. Always include resource requests/limits and health checks

---

## Summary: The Golden Rules

1. **Everything on Kubernetes** - All infrastructure defined as K8s resources
2. **Single Namespace** - All resources in `snoop` namespace
3. **NodePort for External** - Use reserved ranges (frontend: 300xx, API: 301xx, data: 302xx, dev: 303xx)
4. **PVCs for State** - MongoDB (and any future stateful service) uses PersistentVolumeClaims
5. **ConfigMaps for Config** - Non-sensitive config in ConfigMaps
6. **Secrets for Credentials** - JWT_SECRET, API tokens, SMTP credentials never in git
7. **Kubernetes DNS** - Internal services use `<service>:port`, frontend uses external URLs
8. **Resource Limits** - Always define requests and limits (mind Puppeteer memory needs)
9. **Health Checks** - Backend uses `/health`, frontend uses TCP, MongoDB uses TCP
10. **Minikube Compatible** - All definitions work with minikube out-of-box

---

## How Claude Should Use This Skill

When creating or modifying K8s resources:

- **Use `snoop` namespace** for everything
- **Reference the port table** before assigning NodePorts
- **Use the exact env vars** from the ConfigMap/Secret definitions above
- **Remember the frontend caveat** - browser apps can't use K8s DNS, they need external URLs
- **Account for Puppeteer** - backend needs higher memory limits due to Chromium
- **Follow the directory layout** when creating new manifests
- **If adding a new service**, follow the "Adding New Services" checklist
- **If unclear about any assignment, ASK before implementing**

---

## References

- Kubernetes Documentation: https://kubernetes.io/docs/
- Minikube Documentation: https://minikube.sigs.k8s.io/docs/
