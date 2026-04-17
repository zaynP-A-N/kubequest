#!/bin/bash
# =============================================================================
# setup-sealed-secrets.sh — KubeQuest Group-53
#
# Installe Sealed Secrets et chiffre les credentials pour GitOps sécurisé.
#
# PRÉREQUIS :
#   - Cluster Kubernetes opérationnel
#   - kubectl configuré (tunnel SSH actif)
#   - helm installé sur le Mac
#   - values-secrets.yaml créé depuis values-secrets.yaml.example
#
# USAGE (lundi matin, après avoir relancé les tunnels) :
#   cd kubernetes
#   bash scripts/setup-sealed-secrets.sh
#
# CE QUE ÇA FAIT :
#   1. Installe le Sealed Secrets controller dans le cluster
#   2. Installe kubeseal CLI sur le Mac
#   3. Récupère la clé publique du controller
#   4. Chiffre les credentials → sealed-mysql-secret.yaml (safe to commit)
#   5. Met à jour le Helm chart pour utiliser le SealedSecret
# =============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()  { echo -e "${GREEN}[$(date +%H:%M:%S)] $1${NC}"; }
info() { echo -e "${YELLOW}  → $1${NC}"; }
step() { echo -e "\n${BLUE}════════════════════════════════════════${NC}"; echo -e "${BLUE} $1${NC}"; echo -e "${BLUE}════════════════════════════════════════${NC}"; }

CHART_DIR="$(cd "$(dirname "$0")/../helm/kubequest-app" && pwd)"
SEALED_DIR="$(cd "$(dirname "$0")/../sealed-secrets" && pwd)"
SECRETS_FILE="$CHART_DIR/values-secrets.yaml"

# ── Vérifications préliminaires ────────────────────────────────────────────
step "0. Vérifications"

if ! kubectl get nodes &>/dev/null; then
  echo -e "${RED}✗ kubectl ne répond pas. Vérifie le tunnel SSH :${NC}"
  echo "  ssh -L 6443:10.2.53.35:6443 node-1 -N -f"
  exit 1
fi
log "✓ kubectl opérationnel"

if [ ! -f "$SECRETS_FILE" ]; then
  echo -e "${RED}✗ values-secrets.yaml introuvable.${NC}"
  echo "  Crée-le depuis le template :"
  echo "  cp $CHART_DIR/values-secrets.yaml.example $SECRETS_FILE"
  echo "  Puis remplis les valeurs."
  exit 1
fi
log "✓ values-secrets.yaml présent"

# Vérifier que les placeholders ont été remplacés
if grep -q "CHANGE_ME" "$SECRETS_FILE"; then
  echo -e "${RED}✗ values-secrets.yaml contient encore des CHANGE_ME.${NC}"
  echo "  Édite le fichier et remplace toutes les valeurs."
  exit 1
fi
log "✓ Aucun CHANGE_ME détecté dans values-secrets.yaml"

# Lire les valeurs depuis values-secrets.yaml
DB_NAME=$(grep "database:" "$SECRETS_FILE" | awk '{print $2}' | tr -d '"')
DB_USER=$(grep "user:" "$SECRETS_FILE" | awk '{print $2}' | tr -d '"')
DB_PASS=$(grep "password:" "$SECRETS_FILE" | grep -v root | awk '{print $2}' | tr -d '"')
DB_ROOT=$(grep "rootPassword:" "$SECRETS_FILE" | awk '{print $2}' | tr -d '"')
APP_KEY=$(grep "appKey:" "$SECRETS_FILE" | awk '{print $2}' | tr -d '"')

# ── Étape 1 : Installer Sealed Secrets controller ─────────────────────────
step "1. Installation Sealed Secrets controller"

if kubectl get deployment sealed-secrets-controller -n kube-system &>/dev/null; then
  info "Sealed Secrets controller déjà installé"
else
  helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets
  helm repo update

  helm upgrade --install sealed-secrets sealed-secrets/sealed-secrets \
    --namespace kube-system \
    --set fullnameOverride=sealed-secrets-controller

  log "Sealed Secrets controller installé"
  info "Attente démarrage du controller (30s)..."
  sleep 30
fi

kubectl rollout status deployment/sealed-secrets-controller -n kube-system --timeout=60s
log "✓ Controller opérationnel"

# ── Étape 2 : Installer kubeseal CLI ──────────────────────────────────────
step "2. Installation kubeseal CLI"

if command -v kubeseal &>/dev/null; then
  info "kubeseal déjà installé : $(kubeseal --version)"
else
  # ARM64 Mac (Apple Silicon) ou x86_64
  ARCH=$(uname -m)
  if [ "$ARCH" = "arm64" ]; then
    KUBESEAL_ARCH="arm64"
  else
    KUBESEAL_ARCH="amd64"
  fi

  KUBESEAL_VERSION="0.27.0"
  curl -sL "https://github.com/bitnami-labs/sealed-secrets/releases/download/v${KUBESEAL_VERSION}/kubeseal-${KUBESEAL_VERSION}-darwin-${KUBESEAL_ARCH}.tar.gz" \
    | tar xz kubeseal
  sudo mv kubeseal /usr/local/bin/kubeseal
  log "✓ kubeseal installé"
fi

# ── Étape 3 : Récupérer la clé publique du controller ─────────────────────
step "3. Récupération de la clé publique"

mkdir -p "$SEALED_DIR"
kubeseal --fetch-cert \
  --controller-name=sealed-secrets-controller \
  --controller-namespace=kube-system \
  > "$SEALED_DIR/sealed-secrets-cert.pem"

log "✓ Clé publique sauvegardée dans sealed-secrets/sealed-secrets-cert.pem"
info "Cette clé publique peut être committée en Git — elle ne permet que de chiffrer"

# ── Étape 4 : Créer et chiffrer le Secret mysql ───────────────────────────
step "4. Chiffrement des credentials MySQL"

# Créer un Secret K8s temporaire (en mémoire, pas appliqué au cluster)
kubectl create secret generic mysql-secret \
  --namespace=app \
  --from-literal=mysql-database="$DB_NAME" \
  --from-literal=mysql-user="$DB_USER" \
  --from-literal=mysql-password="$DB_PASS" \
  --from-literal=mysql-root-password="$DB_ROOT" \
  --dry-run=client \
  -o yaml \
  | kubeseal \
    --cert "$SEALED_DIR/sealed-secrets-cert.pem" \
    --format yaml \
  > "$SEALED_DIR/sealed-mysql-secret.yaml"

log "✓ sealed-mysql-secret.yaml créé (chiffré, safe to commit)"

# ── Étape 5 : Créer et chiffrer le Secret app (APP_KEY) ───────────────────
step "5. Chiffrement de l'APP_KEY Laravel"

kubectl create secret generic app-secret \
  --namespace=app \
  --from-literal=app-key="$APP_KEY" \
  --dry-run=client \
  -o yaml \
  | kubeseal \
    --cert "$SEALED_DIR/sealed-secrets-cert.pem" \
    --format yaml \
  > "$SEALED_DIR/sealed-app-secret.yaml"

log "✓ sealed-app-secret.yaml créé"

# ── Étape 6 : Instructions suivantes ──────────────────────────────────────
step "TERMINÉ — Prochaines étapes"

echo ""
echo -e "${GREEN}Fichiers créés :${NC}"
echo "  kubernetes/sealed-secrets/sealed-secrets-cert.pem  ← clé publique (commitable)"
echo "  kubernetes/sealed-secrets/sealed-mysql-secret.yaml ← chiffré (commitable)"
echo "  kubernetes/sealed-secrets/sealed-app-secret.yaml   ← chiffré (commitable)"
echo ""
echo -e "${YELLOW}Maintenant il faut :${NC}"
echo "  1. Déplacer les SealedSecrets dans le Helm chart :"
echo "       cp kubernetes/sealed-secrets/sealed-*.yaml \\"
echo "          kubernetes/helm/kubequest-app/templates/"
echo ""
echo "  2. Supprimer l'ancien template mysql-secret.yaml :"
echo "       rm kubernetes/helm/kubequest-app/templates/mysql-secret.yaml"
echo ""
echo "  3. Mettre à jour app.yaml pour lire APP_KEY depuis app-secret :"
echo "       (voir documentation/09-phase7-sealed-secrets.md)"
echo ""
echo "  4. Nettoyer values.yaml (supprimer les credentials)"
echo ""
echo "  5. Committer et pusher :"
echo "       git add kubernetes/sealed-secrets/ kubernetes/helm/"
echo "       git commit -m 'feat(security): replace plain secrets with SealedSecrets'"
echo "       git push"
echo ""
echo -e "${GREEN}✓ ArgoCD déploiera automatiquement les SealedSecrets${NC}"
echo -e "${GREEN}  Le controller les déchiffrera dans le cluster${NC}"
echo ""
