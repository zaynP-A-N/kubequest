#!/bin/bash
# =============================================================================
# install-node.sh — KubeQuest
# Prépare un nœud Ubuntu 20.04 pour Kubernetes 1.29
#
# Usage (depuis ta machine, sur chaque nœud) :
#   ssh k8s-master  "bash -s" < kubernetes/scripts/install-node.sh
#   ssh k8s-node01  "bash -s" < kubernetes/scripts/install-node.sh
#   ssh k8s-node02  "bash -s" < kubernetes/scripts/install-node.sh
#
# Ce script est IDEMPOTENT : tu peux le relancer sans danger.
# =============================================================================

set -euo pipefail

# ── Couleurs pour les logs ────────────────────────────────────────────────────
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()  { echo -e "${GREEN}[$(date +%H:%M:%S)] ✔  $1${NC}"; }
info() { echo -e "${YELLOW}[$(date +%H:%M:%S)] ➜  $1${NC}"; }
err()  { echo -e "${RED}[$(date +%H:%M:%S)] ✖  $1${NC}"; exit 1; }

log "=============================================="
log " KubeQuest — Préparation du nœud : $(hostname)"
log "=============================================="

# ── 1. Mise à jour système ────────────────────────────────────────────────────
log "=== 1. Mise à jour du système ==="
sudo apt-get update -qq
sudo apt-get upgrade -y -qq
sudo apt-get install -y -qq \
  ca-certificates curl gnupg lsb-release \
  apt-transport-https software-properties-common
log "Système à jour"

# ── 2. Désactivation du swap ──────────────────────────────────────────────────
log "=== 2. Désactivation du swap ==="
# Le swap DOIT être désactivé : Kubernetes gère lui-même la mémoire
# et le swap fausse ses décisions de scheduling
sudo swapoff -a
sudo sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab
# Vérification : doit retourner 0
SWAP=$(free -m | awk '/Swap/ {print $2}')
[ "$SWAP" -eq 0 ] && log "Swap désactivé" || err "Swap toujours actif"

# ── 3. Modules kernel ────────────────────────────────────────────────────────
log "=== 3. Chargement des modules kernel ==="
# overlay     : système de fichiers en couches des conteneurs
# br_netfilter : permet à iptables de voir le trafic des bridges réseau
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf > /dev/null
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter

# Vérification
lsmod | grep -q overlay     && log "Module overlay chargé"     || err "Module overlay manquant"
lsmod | grep -q br_netfilter && log "Module br_netfilter chargé" || err "Module br_netfilter manquant"

# ── 4. Paramètres réseau kernel ───────────────────────────────────────────────
log "=== 4. Configuration sysctl réseau ==="
# ip_forward              : routage entre les pods (indispensable)
# bridge-nf-call-iptables : iptables voit le trafic bridge (obligatoire K8s)
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf > /dev/null
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sudo sysctl --system > /dev/null 2>&1
log "Paramètres sysctl appliqués"

# ── 5. Installation de containerd ─────────────────────────────────────────────
log "=== 5. Installation de containerd ==="
# containerd est le runtime de conteneurs recommandé pour Kubernetes
if ! command -v containerd &>/dev/null; then
  sudo mkdir -p /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg

  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

  sudo apt-get update -qq
  sudo apt-get install -y -qq containerd.io
  info "containerd installé : $(containerd --version)"
else
  info "containerd déjà installé : $(containerd --version)"
fi

# Configuration : SystemdCgroup OBLIGATOIRE avec kubeadm
# Sans ça, kubelet et containerd utilisent des cgroup drivers différents
# → les pods crashent au démarrage
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml > /dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

# Vérification
grep -q "SystemdCgroup = true" /etc/containerd/config.toml \
  && log "SystemdCgroup activé" \
  || err "Échec configuration SystemdCgroup"

sudo systemctl restart containerd
sudo systemctl enable containerd
log "containerd démarré et activé"

# ── 6. Installation de kubeadm, kubelet, kubectl ──────────────────────────────
log "=== 6. Installation de kubeadm / kubelet / kubectl (v1.29) ==="
if ! command -v kubeadm &>/dev/null; then
  sudo mkdir -p /etc/apt/keyrings

  curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.29/deb/Release.key \
    | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

  # Écriture sur UNE SEULE LIGNE (évite le bug "Malformed entry")
  sudo rm -f /etc/apt/sources.list.d/kubernetes.list
  echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.29/deb/ /' \
    | sudo tee /etc/apt/sources.list.d/kubernetes.list

  sudo apt-get update -qq
  sudo apt-get install -y kubelet kubeadm kubectl
  sudo apt-mark hold kubelet kubeadm kubectl
  info "kubeadm installé : $(kubeadm version --output short 2>/dev/null)"
else
  info "kubeadm déjà installé : $(kubeadm version --output short 2>/dev/null)"
fi

sudo systemctl enable --now kubelet
log "kubelet activé"

# ── 7. Désactiver unattended-upgrades (évite les locks apt) ──────────────────
log "=== 7. Désactivation des mises à jour automatiques ==="
sudo systemctl stop unattended-upgrades  2>/dev/null || true
sudo systemctl disable unattended-upgrades 2>/dev/null || true
log "unattended-upgrades désactivé"

# ── Récapitulatif ────────────────────────────────────────────────────────────
echo ""
log "=============================================="
log " Installation terminée sur $(hostname)"
log "=============================================="
echo ""
echo "  containerd : $(containerd --version)"
echo "  kubeadm    : $(kubeadm version --output short 2>/dev/null)"
echo "  kubelet    : $(kubelet --version)"
echo "  kubectl    : $(kubectl version --client --short 2>/dev/null)"
echo ""
echo "  PROCHAINE ÉTAPE :"
echo "    Sur k8s-master  : bash kubernetes/scripts/init-master.sh"
echo "    Sur k8s-node01/02 : sudo kubeadm join ..."
echo ""
