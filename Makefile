.PHONY: help k8s-setup k8s-secrets k8s-deploy k8s-status k8s-clean k8s-logs k8s-shell \
       k8s-logging-deploy k8s-logging-status k8s-logging-clean k8s-all

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-25s\033[0m %s\n", $$1, $$2}'

# =============================================================================
# Cluster Setup
# =============================================================================

k8s-setup: ## Setup namespace, storage, and config
	@echo "Creating namespace..."
	kubectl apply -f infra/k8s/namespace.yaml
	@echo "Creating ConfigMaps..."
	kubectl apply -f infra/k8s/config/
	@echo "Setup complete."

k8s-secrets: ## Create secrets from environment variables
	@test -n "$$JWT_SECRET" || (echo "Error: JWT_SECRET not set" && exit 1)
	envsubst < infra/k8s/secrets/backend-secret.yaml.template | kubectl apply -f -
	envsubst < infra/k8s/secrets/frontend-secret.yaml.template | kubectl apply -f -
	@echo "Secrets created."

# =============================================================================
# Application Deployment
# =============================================================================

k8s-deploy: ## Deploy all application services
	@echo "Deploying MongoDB..."
	kubectl apply -f infra/k8s/statefulsets/
	kubectl apply -f infra/k8s/services/mongodb-service.yaml
	@echo "Waiting for MongoDB to be ready..."
	kubectl wait --for=condition=ready pod -l app=mongodb -n snoop --timeout=300s
	@echo "Deploying services..."
	kubectl apply -f infra/k8s/services/
	@echo "Deploying applications..."
	kubectl apply -f infra/k8s/deployments/
	@echo "Application deployment complete."

k8s-status: ## Show status of all resources
	@echo "=== Pods ==="
	@kubectl get pods -n snoop -o wide
	@echo ""
	@echo "=== Services ==="
	@kubectl get svc -n snoop
	@echo ""
	@echo "=== PVCs ==="
	@kubectl get pvc -n snoop

k8s-clean: ## Delete all Kubernetes resources (entire namespace)
	kubectl delete namespace snoop

k8s-logs: ## Show logs for a service (usage: make k8s-logs SERVICE=backend)
	kubectl logs -f -l app=$(SERVICE) -n snoop

k8s-shell: ## Shell into a service (usage: make k8s-shell SERVICE=backend)
	kubectl exec -it deployment/$(SERVICE) -n snoop -- /bin/sh

# =============================================================================
# Logging Stack
# =============================================================================

k8s-logging-deploy: ## Deploy the logging stack (Loki + Alloy + Grafana)
	@echo "Creating RBAC..."
	kubectl apply -f infra/k8s/logging/alloy-rbac.yaml
	@echo "Creating logging ConfigMaps..."
	kubectl apply -f infra/k8s/logging/loki-configmap.yaml
	kubectl apply -f infra/k8s/logging/alloy-configmap.yaml
	kubectl apply -f infra/k8s/logging/grafana-datasources-configmap.yaml
	kubectl apply -f infra/k8s/logging/grafana-dashboard-provisioner-configmap.yaml
	kubectl apply -f infra/k8s/logging/grafana-dashboard-configmap.yaml
	@echo "Deploying Loki..."
	kubectl apply -f infra/k8s/logging/loki-statefulset.yaml
	kubectl apply -f infra/k8s/logging/loki-service.yaml
	kubectl wait --for=condition=ready pod -l app=loki -n snoop --timeout=120s
	@echo "Deploying Alloy..."
	kubectl apply -f infra/k8s/logging/alloy-daemonset.yaml
	@echo "Deploying Grafana..."
	kubectl apply -f infra/k8s/logging/grafana-deployment.yaml
	kubectl apply -f infra/k8s/logging/grafana-service.yaml
	@echo "Logging stack deployed."

k8s-logging-status: ## Show logging stack status
	@kubectl get pods -l tier=logging -n snoop
	@kubectl get svc -l tier=logging -n snoop

k8s-logging-clean: ## Remove logging stack
	kubectl delete -f infra/k8s/logging/ --ignore-not-found

# =============================================================================
# All-in-One
# =============================================================================

k8s-all: k8s-setup k8s-secrets k8s-deploy k8s-logging-deploy ## Deploy everything (setup + app + logging)
	@echo ""
	@echo "All services deployed. Access points:"
	@echo "  Frontend:  http://$$(minikube ip):30000"
	@echo "  Backend:   http://$$(minikube ip):30100"
	@echo "  Grafana:   http://$$(minikube ip):30500"
	@echo "  MailHog:   http://$$(minikube ip):30300"
