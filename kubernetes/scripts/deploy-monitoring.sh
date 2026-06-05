#!/bin/bash
# =============================================================================
# deploy-monitoring.sh — KubeQuest
# Déploie Prometheus + Grafana via Helm (kube-prometheus-stack)
#
# Usage : bash kubernetes/scripts/deploy-monitoring.sh
# Accès après déploiement :
#   Grafana   → http://<MASTER_IP>:30300  (admin / kubequest)
#   Prometheus → http://<MASTER_IP>:30090
# =============================================================================

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[$(date +%H:%M:%S)] ✔  $1${NC}"; }
info() { echo -e "${YELLOW}[$(date +%H:%M:%S)] ➜  $1${NC}"; }

MASTER_IP=$(kubectl get nodes -l node-role.kubernetes.io/control-plane \
  -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')

log "=== Déploiement du monitoring ==="

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -

helm upgrade --install kube-prometheus-stack \
  prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --set grafana.adminPassword=kubequest \
  --set grafana.service.type=NodePort \
  --set grafana.service.nodePort=30300 \
  --set "grafana.resources.requests.memory=128Mi" \
  --set "grafana.resources.limits.memory=256Mi" \
  --set prometheus.service.type=NodePort \
  --set prometheus.service.nodePort=30090 \
  --set "prometheus.prometheusSpec.retention=7d" \
  --set "prometheus.prometheusSpec.resources.requests.memory=256Mi" \
  --set "prometheus.prometheusSpec.resources.limits.memory=512Mi" \
  --set "alertmanager.alertmanagerSpec.resources.requests.memory=64Mi" \
  --set "alertmanager.alertmanagerSpec.resources.limits.memory=128Mi" \
  --set "prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.storageClassName=local-path" \
  --set "prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.resources.requests.storage=3Gi" \
  --timeout 600s \
  --wait

log "=== Monitoring déployé ==="
echo ""
echo "  Grafana   → http://${MASTER_IP}:30300"
echo "  Login     → admin / kubequest"
echo "  Prometheus → http://${MASTER_IP}:30090"
echo ""
kubectl get pods -n monitoring
