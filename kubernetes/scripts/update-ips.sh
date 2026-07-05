#!/bin/bash
# =============================================================================
# update-ips.sh — KubeQuest Group-53
# À lancer chaque matin après le redémarrage des instances par l'école
#
# Pourquoi ? Les IPs de node-2/3/4 changent à chaque restart.
#             node-1 a une Elastic IP fixe (3.74.128.83).
#
# Usage:
#   bash kubernetes/scripts/update-ips.sh <IP_NODE2> <IP_NODE3> <IP_NODE4>
#
# Exemple:
#   bash kubernetes/scripts/update-ips.sh 3.67.x.x 18.195.x.x 51.x.x.x
#
# Pour trouver les nouvelles IPs :
#   Console AWS → EC2 → Instances → filtrer "group-53"
# =============================================================================

set -e

# --- Couleurs pour lisibilité ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

if [ $# -ne 3 ]; then
  echo ""
  echo -e "${YELLOW}Usage:${NC} bash update-ips.sh <IP_NODE2> <IP_NODE3> <IP_NODE4>"
  echo ""
  echo "  node-1 → 3.74.128.83 (Elastic IP fixe, pas besoin de la changer)"
  echo "  node-2 → IP worker 1"
  echo "  node-3 → IP worker 2 (ingress)"
  echo "  node-4 → IP worker 3 (monitoring)"
  echo ""
  exit 1
fi

IP1="3.74.128.83"  # Elastic IP fixe
IP2=$1
IP3=$2
IP4=$3

KEY="$HOME/.ssh/kubequest-group53.pem"

echo ""
echo -e "${YELLOW}=== Mise à jour SSH config ===${NC}"

cat > ~/.ssh/config << EOF
# KubeQuest Group-53 — Mis à jour le $(date)
# node-1 = control-plane (Elastic IP fixe)
# node-2,3,4 = workers (IPs dynamiques)

Host node-1
    HostName $IP1
    User ec2-user
    IdentityFile $KEY
    StrictHostKeyChecking no
    ServerAliveInterval 30

Host node-2
    HostName $IP2
    User ec2-user
    IdentityFile $KEY
    StrictHostKeyChecking no
    ServerAliveInterval 30

Host node-3
    HostName $IP3
    User ec2-user
    IdentityFile $KEY
    StrictHostKeyChecking no
    ServerAliveInterval 30

Host node-4
    HostName $IP4
    User ec2-user
    IdentityFile $KEY
    StrictHostKeyChecking no
    ServerAliveInterval 30
EOF

echo -e "${GREEN}✓ ~/.ssh/config mis à jour${NC}"
echo "  node-1 → $IP1 (fixe)"
echo "  node-2 → $IP2"
echo "  node-3 → $IP3"
echo "  node-4 → $IP4"
echo ""

echo -e "${YELLOW}=== Test des connexions SSH ===${NC}"
ALL_OK=true
for node in node-1 node-2 node-3 node-4; do
  printf "  ssh %-10s → " "$node"
  if ssh -o ConnectTimeout=8 "$node" hostname 2>/dev/null; then
    echo -e "${GREEN}OK${NC}"
  else
    echo -e "${RED}ECHEC${NC}"
    ALL_OK=false
  fi
done

echo ""
if [ "$ALL_OK" = true ]; then
  echo -e "${GREEN}✓ Toutes les connexions sont opérationnelles.${NC}"
  echo -e "${GREEN}  Tu peux continuer à travailler.${NC}"
else
  echo -e "${RED}✗ Certaines connexions ont échoué.${NC}"
  echo "  Vérifie les IPs sur la console AWS."
fi
echo ""
