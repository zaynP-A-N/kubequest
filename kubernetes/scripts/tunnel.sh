#!/bin/bash
# =============================================================================
# tunnel.sh — KubeQuest Group-53
# Ouvre le tunnel SSH pour utiliser kubectl depuis le Mac
#
# Pourquoi ? Le port 6443 (API Kubernetes) n'est pas ouvert dans le
# Security Group AWS. On fait transiter kubectl par SSH (port 22).
#
# Usage:
#   bash kubernetes/scripts/tunnel.sh          → ouvre le tunnel
#   bash kubernetes/scripts/tunnel.sh stop     → ferme le tunnel
#   bash kubernetes/scripts/tunnel.sh status   → vérifie si actif
# =============================================================================

ACTION=${1:-start}

case $ACTION in
  start)
    # Vérif si tunnel déjà actif
    if pgrep -f "ssh -L 6443" > /dev/null 2>&1; then
      echo "Tunnel déjà actif."
    else
      ssh -L 6443:10.2.53.35:6443 node-1 -N -f
      sleep 2
      echo "✓ Tunnel ouvert : localhost:6443 → node-1:6443"
    fi
    echo ""
    echo "Test:"
    kubectl get nodes
    ;;
  stop)
    pkill -f "ssh -L 6443" && echo "✓ Tunnel fermé" || echo "Aucun tunnel actif"
    ;;
  status)
    if pgrep -f "ssh -L 6443" > /dev/null 2>&1; then
      echo "✓ Tunnel actif (PID: $(pgrep -f 'ssh -L 6443'))"
      kubectl get nodes
    else
      echo "✗ Tunnel inactif — lance: bash kubernetes/scripts/tunnel.sh"
    fi
    ;;
  *)
    echo "Usage: $0 [start|stop|status]"
    ;;
esac
