#!/bin/bash
# =============================================================================
# install-node.sh — KubeQuest Group-53
# Prépare un nœud Amazon Linux 2023 (ARM64) pour Kubernetes
#
# Ce script est IDEMPOTENT : tu peux le relancer sans danger si une étape
# a échoué. Il vérifie ce qui est déjà installé avant de tout refaire.
#
# À lancer sur CHAQUE nœud (node-1, node-2, node-3, node-4) :
#   ssh node-X "bash -s" < kubernetes/scripts/install-node.sh
# =============================================================================

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[$(date +%H:%M:%S)] $1${NC}"; }
info() { echo -e "${YELLOW}  → $1${NC}"; }

log "=== 1. Désactivation du swap ==="
# Le swap DOIT être désactivé pour Kubernetes (il fausse la gestion mémoire)
sudo swapoff -a
sudo sed -i '/swap/d' /etc/fstab
info "Swap désactivé"

log "=== 2. Modules kernel nécessaires ==="
# overlay   : système de fichiers des conteneurs
# br_netfilter : permet à iptables de voir le trafic des bridges réseau
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
sudo modprobe overlay
sudo modprobe br_netfilter
info "Modules overlay et br_netfilter chargés"

log "=== 3. Paramètres réseau kernel ==="
# ip_forward : permet le routage entre les pods
# bridge-nf-call-iptables : iptables voit le trafic bridge (obligatoire K8s)
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sudo sysctl --system | grep -E "ip_forward|bridge-nf"
info "Paramètres sysctl appliqués"

log "=== 4. Installation de containerd ==="
# containerd est le runtime de conteneurs recommandé pour Kubernetes
# Il remplace Docker (Docker était trop lourd comme runtime K8s)
if ! command -v containerd &>/dev/null; then
  sudo dnf install -y containerd
else
  info "containerd déjà installé : $(containerd --version)"
fi

# Configuration : activer le cgroup driver systemd (obligatoire avec kubeadm)
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml > /dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sudo systemctl enable --now containerd
info "containerd configuré avec SystemdCgroup=true"

log "=== 5. Installation de kubeadm, kubelet, kubectl ==="
# kubeadm  : outil pour bootstrapper le cluster
# kubelet  : agent qui tourne sur chaque nœud et fait tourner les pods
# kubectl  : CLI pour interagir avec le cluster (surtout utile sur node-1)
if ! command -v kubeadm &>/dev/null; then
  cat <<EOF | sudo tee /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v1.29/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v1.29/rpm/repodata/repomd.xml.key
exclude=kubelet kubeadm kubectl cri-tools kubernetes-cni
EOF
  sudo dnf install -y kubelet kubeadm kubectl --disableexcludes=kubernetes
else
  info "kubeadm déjà installé : $(kubeadm version --output short 2>/dev/null)"
fi

sudo systemctl enable --now kubelet
info "kubelet activé"

log "=== Installation terminée sur $(hostname) ==="
echo ""
echo "Versions installées :"
echo "  containerd : $(containerd --version)"
echo "  kubeadm    : $(kubeadm version --output short 2>/dev/null)"
echo "  kubelet    : $(kubelet --version)"
echo "  kubectl    : $(kubectl version --client --short 2>/dev/null)"
echo ""
echo "PROCHAINE ÉTAPE :"
echo "  Sur node-1 uniquement : sudo kubeadm init ..."
echo "  Sur node-2/3/4        : sudo kubeadm join ..."
