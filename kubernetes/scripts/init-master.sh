#!/bin/bash
# =============================================================================
# init-master.sh — KubeQuest
# Initialise le control-plane Kubernetes sur k8s-master
#
# Usage (sur k8s-master uniquement) :
#   bash kubernetes/scripts/init-master.sh
#
# Prérequis : install-node.sh doit avoir été exécuté avant
# =============================================================================

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()  { echo -e "${GREEN}[$(date +%H:%M:%S)] ✔  $1${NC}"; }
info() { echo -e "${YELLOW}[$(date +%H:%M:%S)] ➜  $1${NC}"; }
err()  { echo -e "${RED}[$(date +%H:%M:%S)] ✖  $1${NC}"; exit 1; }

# ── Détection automatique de l'IP du master ───────────────────────────────────
MASTER_IP=$(hostname -I | awk '{print $1}')
info "IP détectée pour le master : $MASTER_IP"
info "Si cette IP est incorrecte, modifie MASTER_IP dans ce script"

log "=============================================="
log " KubeQuest — Initialisation du control-plane"
log "=============================================="

# ── 1. Initialisation kubeadm ─────────────────────────────────────────────────
log "=== 1. kubeadm init ==="
# pod-network-cidr=10.244.0.0/16 : CIDR des pods (différent du réseau des VMs)
# On vérifie d'abord que le cluster n'existe pas déjà
if kubectl get nodes &>/dev/null 2>&1; then
  info "Cluster déjà initialisé, skip kubeadm init"
else
  sudo kubeadm init \
    --apiserver-advertise-address="${MASTER_IP}" \
    --pod-network-cidr=10.244.0.0/16 \
    --kubernetes-version=1.29.0 \
    | tee /tmp/kubeadm-init.log

  log "Cluster initialisé"
fi

# ── 2. Configuration kubectl ──────────────────────────────────────────────────
log "=== 2. Configuration kubectl ==="
mkdir -p "$HOME/.kube"
sudo cp -f /etc/kubernetes/admin.conf "$HOME/.kube/config"
sudo chown "$(id -u):$(id -g)" "$HOME/.kube/config"
log "kubectl configuré"

# ── 3. Installation CNI — Calico ──────────────────────────────────────────────
log "=== 3. Installation du CNI Calico ==="
# Calico gère le réseau entre pods (sans lui les pods ne peuvent pas communiquer)
# On adapte le CIDR pour éviter le conflit avec notre réseau VMware
if ! kubectl get daemonset calico-node -n kube-system &>/dev/null 2>&1; then
  curl -fsSL https://raw.githubusercontent.com/projectcalico/calico/v3.27.0/manifests/calico.yaml -o /tmp/calico.yaml
  # Remplace le CIDR par défaut Calico (192.168.0.0/16) par notre CIDR (10.244.0.0/16)
  sed -i 's/192.168.0.0\/16/10.244.0.0\/16/g' /tmp/calico.yaml
  kubectl apply -f /tmp/calico.yaml
  log "Calico appliqué"
else
  info "Calico déjà installé"
fi

# ── 4. Attente que le control-plane soit Ready ────────────────────────────────
log "=== 4. Attente du démarrage des pods système ==="
info "Cela peut prendre 2 à 5 minutes..."
kubectl wait --for=condition=Ready nodes/${HOSTNAME,,} \
  --timeout=300s 2>/dev/null || true

# ── 5. Installation local-path-provisioner ────────────────────────────────────
log "=== 5. Installation du StorageClass local-path ==="
# Fournit le provisionnement dynamique de PersistentVolumes
# Les pods peuvent demander du stockage sans PV manuel
if ! kubectl get storageclass local-path &>/dev/null 2>&1; then
  kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.26/deploy/local-path-storage.yaml
  # Définir comme StorageClass par défaut
  kubectl patch storageclass local-path \
    -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
  log "local-path-provisioner installé et défini par défaut"
else
  info "local-path-provisioner déjà installé"
fi

# ── 6. Installation Helm ──────────────────────────────────────────────────────
log "=== 6. Installation de Helm ==="
if ! command -v helm &>/dev/null; then
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  log "Helm installé : $(helm version --short)"
else
  info "Helm déjà installé : $(helm version --short)"
fi

# ── 7. Installation NGINX Ingress Controller ──────────────────────────────────
log "=== 7. Installation NGINX Ingress Controller ==="
if ! helm list -n ingress-nginx 2>/dev/null | grep -q ingress-nginx; then
  helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
  helm repo update
  helm install ingress-nginx ingress-nginx/ingress-nginx \
    --namespace ingress-nginx \
    --create-namespace \
    --set controller.service.type=NodePort \
    --set controller.service.nodePorts.http=30080 \
    --set controller.service.nodePorts.https=30443 \
    --set controller.resources.requests.memory=128Mi \
    --set controller.resources.limits.memory=256Mi
  log "NGINX Ingress Controller installé (NodePort 30080/30443)"
else
  info "NGINX Ingress Controller déjà installé"
fi

# ── 8. Installation Metrics Server (requis pour HPA) ─────────────────────────
log "=== 8. Installation Metrics Server ==="
if ! kubectl get deployment metrics-server -n kube-system &>/dev/null 2>&1; then
  kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
  # Patch pour environnement sans TLS valide (VMs locales)
  kubectl patch deployment metrics-server -n kube-system \
    --type='json' \
    -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
  log "Metrics Server installé"
else
  info "Metrics Server déjà installé"
fi

# ── Récapitulatif + commande join ─────────────────────────────────────────────
echo ""
log "=============================================="
log " Control-plane prêt !"
log "=============================================="
echo ""
kubectl get nodes -o wide
echo ""
log "=== Commande join pour les workers ==="
kubeadm token create --print-join-command
echo ""
info "Lance cette commande avec 'sudo' sur k8s-node01 et k8s-node02"
