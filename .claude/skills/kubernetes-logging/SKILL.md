# Claude Skill: Kubernetes Logging for Snoop

**Purpose**: Guide the deployment of a centralized logging stack for the Snoop platform using Grafana Loki, Grafana Alloy, and Grafana.

---

## Stack Overview

| Component | Image | Role | K8s Resource |
|-----------|-------|------|--------------|
| **Loki** | `grafana/loki:3.6` | Log storage and query engine | StatefulSet |
| **Alloy** | `grafana/alloy:v1.13.0` | Log collector, scrapes pod logs | DaemonSet |
| **Grafana** | `grafana/grafana:latest` | UI for querying and exploring logs | Deployment |

**Why these tools**:
- **Loki** stores logs indexed by labels (not full-text), making it lightweight and cost-effective
- **Alloy** is Grafana's unified collector, replacing the now-deprecated Promtail (EOL March 2026)
- **Grafana** provides the query UI with LogQL support

All resources deploy to the `snoop` namespace alongside the application services.

---

## NodePort Assignments

These extend the Snoop infrastructure skill's port ranges (30500+ for observability):

| Service | NodePort | Internal Port | Purpose |
|---------|----------|---------------|---------|
| **Grafana** | 30500 | 3000 | Log exploration UI |
| **Loki** | 30501 | 3100 | Loki API (admin/debug only) |

---

## RBAC

Alloy needs cluster-wide permissions to discover pods and read their logs.

```yaml
# infra/k8s/logging/alloy-rbac.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: alloy
  namespace: snoop
  labels:
    app: alloy
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: alloy-logs
rules:
  - apiGroups: [""]
    resources:
      - pods
      - pods/log
      - nodes
      - nodes/proxy
      - namespaces
      - endpoints
    verbs:
      - get
      - list
      - watch
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: alloy-logs
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: alloy-logs
subjects:
  - kind: ServiceAccount
    name: alloy
    namespace: snoop
```

---

## Loki

### Loki ConfigMap

Runs in monolithic (single-binary) mode with filesystem storage, suitable for dev and small deployments.

```yaml
# infra/k8s/logging/loki-configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: loki-config
  namespace: snoop
  labels:
    app: loki
data:
  loki.yaml: |
    auth_enabled: false

    server:
      http_listen_port: 3100

    common:
      path_prefix: /loki
      storage:
        filesystem:
          chunks_directory: /loki/chunks
          rules_directory: /loki/rules
      replication_factor: 1
      ring:
        kvstore:
          store: inmemory

    schema_config:
      configs:
        - from: "2024-01-01"
          store: tsdb
          object_store: filesystem
          schema: v13
          index:
            prefix: index_
            period: 24h

    limits_config:
      retention_period: 168h  # 7 days
      ingestion_rate_mb: 10
      ingestion_burst_size_mb: 20

    compactor:
      working_directory: /loki/compactor
      retention_enabled: true
      delete_request_store: filesystem
```

### Loki StatefulSet

```yaml
# infra/k8s/logging/loki-statefulset.yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: loki
  namespace: snoop
  labels:
    app: loki
    tier: logging
spec:
  serviceName: loki
  replicas: 1
  selector:
    matchLabels:
      app: loki
  template:
    metadata:
      labels:
        app: loki
        tier: logging
    spec:
      containers:
        - name: loki
          image: grafana/loki:3.6
          args:
            - -config.file=/etc/loki/loki.yaml
            - -target=all
          ports:
            - containerPort: 3100
              name: http
          volumeMounts:
            - name: config
              mountPath: /etc/loki
            - name: data
              mountPath: /loki
          resources:
            requests:
              cpu: 100m
              memory: 256Mi
            limits:
              cpu: 1000m
              memory: 1Gi
          readinessProbe:
            httpGet:
              path: /ready
              port: 3100
            initialDelaySeconds: 15
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /ready
              port: 3100
            initialDelaySeconds: 30
            periodSeconds: 10
      volumes:
        - name: config
          configMap:
            name: loki-config
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes: ["ReadWriteOnce"]
        resources:
          requests:
            storage: 10Gi
```

### Loki Service

```yaml
# infra/k8s/logging/loki-service.yaml
apiVersion: v1
kind: Service
metadata:
  name: loki
  namespace: snoop
  labels:
    app: loki
    tier: logging
spec:
  type: NodePort
  selector:
    app: loki
  ports:
    - name: http
      protocol: TCP
      port: 3100
      targetPort: 3100
      nodePort: 30501
```

---

## Alloy (Log Collector)

### Alloy ConfigMap

Discovers all pods in the `snoop` namespace, collects their stdout/stderr logs, attaches Kubernetes labels, and ships to Loki.

```yaml
# infra/k8s/logging/alloy-configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: alloy-config
  namespace: snoop
  labels:
    app: alloy
data:
  config.alloy: |
    // Discover pods in the snoop namespace
    discovery.kubernetes "pods" {
      role = "pod"
      namespaces {
        names = ["snoop"]
      }
    }

    // Filter to only running containers and attach metadata labels
    discovery.relabel "pod_logs" {
      targets = discovery.kubernetes.pods.targets

      rule {
        source_labels = ["__meta_kubernetes_pod_phase"]
        regex         = "Succeeded|Failed"
        action        = "drop"
      }

      rule {
        source_labels = ["__meta_kubernetes_namespace"]
        target_label  = "namespace"
      }

      rule {
        source_labels = ["__meta_kubernetes_pod_name"]
        target_label  = "pod"
      }

      rule {
        source_labels = ["__meta_kubernetes_pod_container_name"]
        target_label  = "container"
      }

      rule {
        source_labels = ["__meta_kubernetes_pod_label_app"]
        target_label  = "app"
      }

      rule {
        source_labels = ["__meta_kubernetes_pod_label_tier"]
        target_label  = "tier"
      }
    }

    // Read logs from discovered pod log files on the node
    loki.source.kubernetes "pod_logs" {
      targets    = discovery.relabel.pod_logs.output
      forward_to = [loki.process.pod_logs.receiver]
    }

    // Process: add static labels
    loki.process "pod_logs" {
      stage.static_labels {
        values = {
          cluster = "snoop-dev",
        }
      }
      forward_to = [loki.write.default.receiver]
    }

    // Ship logs to Loki
    loki.write "default" {
      endpoint {
        url = "http://loki.snoop.svc.cluster.local:3100/loki/api/v1/push"
      }
    }
```

### Alloy DaemonSet

Runs one pod per node to collect logs from all containers on that node.

```yaml
# infra/k8s/logging/alloy-daemonset.yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: alloy
  namespace: snoop
  labels:
    app: alloy
    tier: logging
spec:
  selector:
    matchLabels:
      app: alloy
  template:
    metadata:
      labels:
        app: alloy
        tier: logging
    spec:
      serviceAccountName: alloy
      containers:
        - name: alloy
          image: grafana/alloy:v1.13.0
          args:
            - run
            - /etc/alloy/config.alloy
            - --storage.path=/tmp/alloy
          ports:
            - containerPort: 12345
              name: http
          volumeMounts:
            - name: config
              mountPath: /etc/alloy
            - name: varlog
              mountPath: /var/log
              readOnly: true
            - name: dockercontainers
              mountPath: /var/lib/docker/containers
              readOnly: true
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 500m
              memory: 512Mi
          readinessProbe:
            httpGet:
              path: /-/ready
              port: 12345
            initialDelaySeconds: 10
            periodSeconds: 10
      volumes:
        - name: config
          configMap:
            name: alloy-config
        - name: varlog
          hostPath:
            path: /var/log
        - name: dockercontainers
          hostPath:
            path: /var/lib/docker/containers
```

---

## Grafana

### Grafana Datasource ConfigMap

Pre-configures Loki as a data source so it's ready to use immediately.

```yaml
# infra/k8s/logging/grafana-datasources-configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-datasources
  namespace: snoop
  labels:
    app: grafana
data:
  datasources.yaml: |
    apiVersion: 1
    datasources:
      - name: Loki
        type: loki
        access: proxy
        url: http://loki.snoop.svc.cluster.local:3100
        isDefault: true
        editable: false
```

### Grafana Dashboard Provisioner ConfigMap

Tells Grafana to load dashboards from the provisioning directory on startup.

```yaml
# infra/k8s/logging/grafana-dashboard-provisioner-configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboard-provisioner
  namespace: snoop
  labels:
    app: grafana
data:
  dashboards.yaml: |
    apiVersion: 1
    providers:
      - name: snoop
        orgId: 1
        folder: Snoop
        type: file
        disableDeletion: false
        editable: true
        options:
          path: /var/lib/grafana/dashboards
          foldersFromFilesStructure: false
```

### Grafana Dashboard ConfigMap

The pre-built "Snoop Logs" dashboard. Provides an overview of all services with log stream, error rates, volume charts, and per-service filtering.

```yaml
# infra/k8s/logging/grafana-dashboard-configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboards
  namespace: snoop
  labels:
    app: grafana
data:
  snoop-logs.json: |
    {
      "annotations": { "list": [] },
      "editable": true,
      "fiscalYearStartMonth": 0,
      "graphTooltip": 1,
      "links": [],
      "panels": [
        {
          "title": "Log Volume by Service",
          "type": "timeseries",
          "gridPos": { "h": 6, "w": 24, "x": 0, "y": 0 },
          "datasource": { "type": "loki", "uid": "" },
          "targets": [
            {
              "expr": "sum(rate({namespace=\"snoop\", app=~\"$service\"} [$__interval])) by (app)",
              "legendFormat": "{{app}}",
              "refId": "A"
            }
          ],
          "fieldConfig": {
            "defaults": {
              "color": { "mode": "palette-classic" },
              "custom": {
                "fillOpacity": 30,
                "lineWidth": 1,
                "stacking": { "mode": "normal" },
                "drawStyle": "bars",
                "barAlignment": 0
              },
              "unit": "short"
            },
            "overrides": []
          },
          "options": {
            "tooltip": { "mode": "multi" },
            "legend": { "displayMode": "list", "placement": "bottom" }
          }
        },
        {
          "title": "Error Rate by Service",
          "type": "timeseries",
          "gridPos": { "h": 6, "w": 12, "x": 0, "y": 6 },
          "datasource": { "type": "loki", "uid": "" },
          "targets": [
            {
              "expr": "sum(rate({namespace=\"snoop\", app=~\"$service\"} |~ \"(?i)error|exception|fatal|panic\" [$__interval])) by (app)",
              "legendFormat": "{{app}}",
              "refId": "A"
            }
          ],
          "fieldConfig": {
            "defaults": {
              "color": { "mode": "palette-classic" },
              "custom": {
                "fillOpacity": 20,
                "lineWidth": 2,
                "drawStyle": "line",
                "pointSize": 5
              },
              "unit": "short"
            },
            "overrides": []
          },
          "options": {
            "tooltip": { "mode": "multi" },
            "legend": { "displayMode": "list", "placement": "bottom" }
          }
        },
        {
          "title": "Warning Rate by Service",
          "type": "timeseries",
          "gridPos": { "h": 6, "w": 12, "x": 12, "y": 6 },
          "datasource": { "type": "loki", "uid": "" },
          "targets": [
            {
              "expr": "sum(rate({namespace=\"snoop\", app=~\"$service\"} |~ \"(?i)warn\" [$__interval])) by (app)",
              "legendFormat": "{{app}}",
              "refId": "A"
            }
          ],
          "fieldConfig": {
            "defaults": {
              "color": { "mode": "palette-classic" },
              "custom": {
                "fillOpacity": 20,
                "lineWidth": 2,
                "drawStyle": "line",
                "pointSize": 5
              },
              "unit": "short"
            },
            "overrides": []
          },
          "options": {
            "tooltip": { "mode": "multi" },
            "legend": { "displayMode": "list", "placement": "bottom" }
          }
        },
        {
          "title": "Errors & Exceptions",
          "type": "logs",
          "gridPos": { "h": 8, "w": 24, "x": 0, "y": 12 },
          "datasource": { "type": "loki", "uid": "" },
          "targets": [
            {
              "expr": "{namespace=\"snoop\", app=~\"$service\"} |~ \"(?i)error|exception|fatal|panic\"",
              "refId": "A"
            }
          ],
          "options": {
            "showTime": true,
            "showLabels": true,
            "showCommonLabels": false,
            "wrapLogMessage": true,
            "prettifyLogMessage": false,
            "enableLogDetails": true,
            "sortOrder": "Descending",
            "dedupStrategy": "none"
          }
        },
        {
          "title": "Live Log Stream",
          "type": "logs",
          "gridPos": { "h": 12, "w": 24, "x": 0, "y": 20 },
          "datasource": { "type": "loki", "uid": "" },
          "targets": [
            {
              "expr": "{namespace=\"snoop\", app=~\"$service\"}",
              "refId": "A"
            }
          ],
          "options": {
            "showTime": true,
            "showLabels": true,
            "showCommonLabels": false,
            "wrapLogMessage": true,
            "prettifyLogMessage": false,
            "enableLogDetails": true,
            "sortOrder": "Descending",
            "dedupStrategy": "none"
          }
        }
      ],
      "schemaVersion": 39,
      "tags": ["snoop", "loki", "logs"],
      "templating": {
        "list": [
          {
            "name": "service",
            "type": "query",
            "datasource": { "type": "loki", "uid": "" },
            "query": { "label": "app", "stream": "{namespace=\"snoop\"}", "type": 1 },
            "current": { "selected": true, "text": "All", "value": "$__all" },
            "includeAll": true,
            "allValue": ".+",
            "multi": true,
            "refresh": 2,
            "sort": 1
          }
        ]
      },
      "time": { "from": "now-1h", "to": "now" },
      "timepicker": {},
      "timezone": "browser",
      "title": "Snoop Logs",
      "uid": "snoop-logs-overview"
    }
```

### Grafana Deployment

```yaml
# infra/k8s/logging/grafana-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: grafana
  namespace: snoop
  labels:
    app: grafana
    tier: logging
spec:
  replicas: 1
  selector:
    matchLabels:
      app: grafana
  template:
    metadata:
      labels:
        app: grafana
        tier: logging
    spec:
      containers:
        - name: grafana
          image: grafana/grafana:latest
          ports:
            - containerPort: 3000
              name: http
          env:
            - name: GF_SECURITY_ADMIN_USER
              value: "admin"
            - name: GF_SECURITY_ADMIN_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: grafana-secret
                  key: admin-password
            - name: GF_AUTH_ANONYMOUS_ENABLED
              value: "true"
            - name: GF_AUTH_ANONYMOUS_ORG_ROLE
              value: "Viewer"
          volumeMounts:
            - name: datasources
              mountPath: /etc/grafana/provisioning/datasources
            - name: dashboard-provisioner
              mountPath: /etc/grafana/provisioning/dashboards
            - name: dashboards
              mountPath: /var/lib/grafana/dashboards
            - name: data
              mountPath: /var/lib/grafana
              subPath: grafana-data
          resources:
            requests:
              cpu: 50m
              memory: 128Mi
            limits:
              cpu: 500m
              memory: 512Mi
          readinessProbe:
            httpGet:
              path: /api/health
              port: 3000
            initialDelaySeconds: 10
            periodSeconds: 10
      volumes:
        - name: datasources
          configMap:
            name: grafana-datasources
        - name: dashboard-provisioner
          configMap:
            name: grafana-dashboard-provisioner
        - name: dashboards
          configMap:
            name: grafana-dashboards
        - name: data
          emptyDir: {}
```

### Grafana Secret

```yaml
# infra/k8s/logging/grafana-secret.yaml.template
apiVersion: v1
kind: Secret
metadata:
  name: grafana-secret
  namespace: snoop
  labels:
    app: grafana
type: Opaque
stringData:
  admin-password: ${GRAFANA_ADMIN_PASSWORD}
```

### Grafana Service

```yaml
# infra/k8s/logging/grafana-service.yaml
apiVersion: v1
kind: Service
metadata:
  name: grafana
  namespace: snoop
  labels:
    app: grafana
    tier: logging
spec:
  type: NodePort
  selector:
    app: grafana
  ports:
    - name: http
      protocol: TCP
      port: 3000
      targetPort: 3000
      nodePort: 30500
```

---

## Resource Allocations

| Component | CPU Request | CPU Limit | Memory Request | Memory Limit | Storage |
|-----------|-------------|-----------|----------------|--------------|---------|
| **Loki** | 100m | 1000m | 256Mi | 1Gi | 10Gi PVC |
| **Alloy** (per node) | 50m | 500m | 64Mi | 512Mi | hostPath only |
| **Grafana** | 50m | 500m | 128Mi | 512Mi | emptyDir |

---

## Directory Layout

```
infra/k8s/logging/
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

---

## Deployment

```bash
# 1. Create RBAC (must be first - Alloy needs permissions)
kubectl apply -f infra/k8s/logging/alloy-rbac.yaml

# 2. Create ConfigMaps
kubectl apply -f infra/k8s/logging/loki-configmap.yaml
kubectl apply -f infra/k8s/logging/alloy-configmap.yaml
kubectl apply -f infra/k8s/logging/grafana-datasources-configmap.yaml
kubectl apply -f infra/k8s/logging/grafana-dashboard-provisioner-configmap.yaml
kubectl apply -f infra/k8s/logging/grafana-dashboard-configmap.yaml

# 3. Create Secrets
envsubst < infra/k8s/logging/grafana-secret.yaml.template | kubectl apply -f -

# 4. Deploy Loki (wait for ready before starting Alloy)
kubectl apply -f infra/k8s/logging/loki-statefulset.yaml
kubectl apply -f infra/k8s/logging/loki-service.yaml
kubectl wait --for=condition=ready pod -l app=loki -n snoop --timeout=120s

# 5. Deploy Alloy
kubectl apply -f infra/k8s/logging/alloy-daemonset.yaml

# 6. Deploy Grafana
kubectl apply -f infra/k8s/logging/grafana-deployment.yaml
kubectl apply -f infra/k8s/logging/grafana-service.yaml
```

### Makefile Targets

```makefile
k8s-logging-deploy: ## Deploy the logging stack (Loki + Alloy + Grafana)
	kubectl apply -f infra/k8s/logging/alloy-rbac.yaml
	kubectl apply -f infra/k8s/logging/loki-configmap.yaml
	kubectl apply -f infra/k8s/logging/alloy-configmap.yaml
	kubectl apply -f infra/k8s/logging/grafana-datasources-configmap.yaml
	kubectl apply -f infra/k8s/logging/grafana-dashboard-provisioner-configmap.yaml
	kubectl apply -f infra/k8s/logging/grafana-dashboard-configmap.yaml
	kubectl apply -f infra/k8s/logging/loki-statefulset.yaml
	kubectl apply -f infra/k8s/logging/loki-service.yaml
	kubectl wait --for=condition=ready pod -l app=loki -n snoop --timeout=120s
	kubectl apply -f infra/k8s/logging/alloy-daemonset.yaml
	kubectl apply -f infra/k8s/logging/grafana-deployment.yaml
	kubectl apply -f infra/k8s/logging/grafana-service.yaml

k8s-logging-status: ## Show logging stack status
	kubectl get pods -l tier=logging -n snoop
	kubectl get svc -l tier=logging -n snoop

k8s-logging-clean: ## Remove logging stack
	kubectl delete -f infra/k8s/logging/ --ignore-not-found
```

---

## Querying Logs

### Access Grafana

```bash
# Open Grafana in browser
minikube service grafana -n snoop --url
# Default: admin / <GRAFANA_ADMIN_PASSWORD>
# Anonymous access enabled as Viewer
```

### Pre-built Dashboard: "Snoop Logs"

Available at **Dashboards > Snoop > Snoop Logs** immediately after deployment. No manual setup needed.

**Panels**:

| Panel | Type | Description |
|-------|------|-------------|
| **Log Volume by Service** | Stacked bar chart | Total log throughput per service over time |
| **Error Rate by Service** | Line chart | Rate of lines matching `error`, `exception`, `fatal`, `panic` |
| **Warning Rate by Service** | Line chart | Rate of lines matching `warn` |
| **Errors & Exceptions** | Log viewer | Filtered stream showing only error/exception lines |
| **Live Log Stream** | Log viewer | Full log output with timestamps and labels |

**Variables**: The `$service` dropdown at the top lets you filter all panels to one or more services (backend, frontend, mongodb, etc.). Defaults to "All".

### Adding More Dashboards

To add a new dashboard:

1. Design it in the Grafana UI (Dashboards > New)
2. Export as JSON: Dashboard settings > JSON Model > Copy
3. Add the JSON to the `grafana-dashboards` ConfigMap in `grafana-dashboard-configmap.yaml` as a new key (e.g., `scraper-performance.json: |`)
4. Reapply: `kubectl apply -f infra/k8s/logging/grafana-dashboard-configmap.yaml`
5. Restart Grafana to pick up changes: `kubectl rollout restart deployment/grafana -n snoop`

### Useful LogQL Queries for Snoop

**All backend logs**:
```
{app="backend"}
```

**Backend errors only**:
```
{app="backend"} |= "error" or {app="backend"} |= "Error"
```

**Backend logs parsed as JSON** (Winston outputs JSON):
```
{app="backend"} | json | level = "error"
```

**MongoDB logs**:
```
{app="mongodb"}
```

**All logs from a specific pod**:
```
{pod="backend-abc123-xyz"}
```

**Logs by tier**:
```
{tier="backend"}
{tier="data"}
{tier="frontend"}
```

**Log volume over time** (for dashboards):
```
sum(rate({namespace="snoop"} [5m])) by (app)
```

**Error rate by service**:
```
sum(rate({namespace="snoop"} |= "error" [5m])) by (app)
```

---

## Verification

```bash
# Check Alloy is collecting logs
kubectl logs -l app=alloy -n snoop --tail=20

# Check Loki is receiving logs
curl http://$(minikube ip):30501/ready

# Query Loki directly
curl -G http://$(minikube ip):30501/loki/api/v1/query \
  --data-urlencode 'query={namespace="snoop"}'

# Verify RBAC
kubectl auth can-i get pods/log --as=system:serviceaccount:snoop:alloy
```

---

## Scaling Notes

This skill configures Loki in **monolithic mode with filesystem storage** - appropriate for development and small deployments. For production scaling:

- **Higher log volume**: Switch Loki to object storage (MinIO or S3) and increase replicas
- **Multi-node clusters**: Alloy DaemonSet automatically scales (one per node)
- **Longer retention**: Increase `retention_period` in Loki config and PVC size
- **Grafana persistence**: Replace `emptyDir` with a PVC if dashboards should survive restarts

---

## How Claude Should Use This Skill

When working on logging infrastructure:

- **Deploy all logging resources to the `snoop` namespace** - same as application services
- **Use the `infra/k8s/logging/` directory** for all logging manifests
- **Deploy Loki before Alloy** - Alloy needs Loki to be ready to push logs
- **Use the RBAC manifests** - Alloy won't work without pod/log read permissions
- **Reference the LogQL examples** when helping users query logs
- **Keep Grafana datasource provisioning automatic** - no manual setup needed
- **If adding new services**, they're automatically picked up by Alloy (no config changes needed for new pods in the snoop namespace)
