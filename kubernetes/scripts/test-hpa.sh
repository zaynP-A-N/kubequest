#!/usr/bin/env bash
# =============================================================================
# test-hpa.sh — Test de charge HPA pour KubeQuest
# =============================================================================
# Lance un test ab depuis node-1 vers le ClusterIP et observe en temps
# réel le scale-up puis le scale-down du HPA.
#
# Usage :
#   ./kubernetes/scripts/test-hpa.sh
#   CONCURRENCY=50 REQUESTS=30000 ./kubernetes/scripts/test-hpa.sh
#
# Variables d'environnement (toutes optionnelles) :
#   NAMESPACE     namespace de l'app        (défaut: app)
#   CONCURRENCY   connexions simultanées    (défaut: 20)
#   REQUESTS      nombre total de requêtes  (défaut: 20000)
#   ENDPOINT      chemin HTTP testé         (défaut: /api/counter/count)
#   HPA_NAME      nom du HPA               (défaut: app-hpa)
#   SVC_NAME      nom du Service app        (défaut: app)
#   NODE          nœud SSH pour ab          (défaut: node-1)
#   POLL           intervalle de polling (s) (défaut: 15)
#   SKIP_SCALEDOWN ne pas attendre scale-down (défaut: false)
# =============================================================================

set -euo pipefail

# ── Couleurs ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# ── Paramètres ────────────────────────────────────────────────────────────────
NAMESPACE="${NAMESPACE:-app}"
CONCURRENCY="${CONCURRENCY:-20}"
REQUESTS="${REQUESTS:-20000}"
ENDPOINT="${ENDPOINT:-/api/counter/count}"
HPA_NAME="${HPA_NAME:-app-hpa}"
SVC_NAME="${SVC_NAME:-app}"
NODE="${NODE:-node-1}"
POLL="${POLL:-15}"
SKIP_SCALEDOWN="${SKIP_SCALEDOWN:-false}"

# ── Helpers ───────────────────────────────────────────────────────────────────
phase()   { echo -e "\n${BLUE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; \
            echo -e "${BLUE}${BOLD}  $1${NC}"; \
            echo -e "${BLUE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }
ok()      { echo -e "${GREEN}  ✓ $1${NC}"; }
warn()    { echo -e "${YELLOW}  ⚠ $1${NC}"; }
err()     { echo -e "${RED}  ✗ $1${NC}"; exit 1; }
info()    { echo -e "    → $1"; }
header()  { printf "${BOLD}  %-6s  %-16s  %-10s  %-12s  %s${NC}\n" \
              "T(s)" "CPU/Seuil" "Replicas" "Pods Ready" "Événement"; \
            printf "  %s\n" "──────  ────────────────  ──────────  ────────────  ──────────────────────"; }

# ── Vérifier qu'une commande existe ───────────────────────────────────────────
need() { command -v "$1" &>/dev/null || err "Commande '$1' introuvable. Installez-la d'abord."; }

# =============================================================================
# PHASE 1 — Prérequis
# =============================================================================
phase "1/6 — Vérifications préalables"

need kubectl
need ssh

# metrics-server
if kubectl top nodes &>/dev/null; then
  ok "metrics-server opérationnel"
else
  err "metrics-server non disponible (kubectl top nodes échoue). Installez-le d'abord."
fi

# HPA
if kubectl get hpa "$HPA_NAME" -n "$NAMESPACE" &>/dev/null; then
  ok "HPA '$HPA_NAME' présent dans le namespace '$NAMESPACE'"
else
  err "HPA '$HPA_NAME' introuvable. Vérifiez le nom (kubectl get hpa -n $NAMESPACE)."
fi

# ab sur node-1 (installation automatique si absent)
if ssh "$NODE" "which ab" &>/dev/null 2>&1; then
  ok "ab (Apache Benchmark) disponible sur $NODE"
else
  warn "ab absent sur $NODE — installation via yum..."
  if ssh "$NODE" "sudo yum install -y httpd-tools" &>/dev/null 2>&1; then
    ok "ab installé sur $NODE"
  else
    err "Impossible d'installer ab sur $NODE. Connectivité SSH ou droits sudo à vérifier."
  fi
fi

# Service + ClusterIP
if APP_SVC_IP=$(kubectl get svc "$SVC_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.spec.clusterIP}' 2>/dev/null) && [[ -n "$APP_SVC_IP" ]]; then
  ok "Service '$SVC_NAME' — ClusterIP: $APP_SVC_IP"
else
  err "Service '$SVC_NAME' introuvable dans le namespace '$NAMESPACE'."
fi

# Test d'accès depuis node-1
info "Test de connectivité node-1 → ClusterIP..."
HTTP_CODE=$(ssh "$NODE" "curl -s -o /dev/null -w '%{http_code}' \
  http://$APP_SVC_IP$ENDPOINT" 2>/dev/null || echo "000")
if [[ "$HTTP_CODE" == "200" ]]; then
  ok "Endpoint accessible (HTTP 200)"
elif [[ "$HTTP_CODE" == "000" ]]; then
  warn "Pas de réponse — le pod est peut-être en cours de démarrage"
else
  warn "Réponse HTTP $HTTP_CODE (le test continuera quand même)"
fi

# =============================================================================
# PHASE 2 — Baseline
# =============================================================================
phase "2/6 — État baseline (avant le test)"

echo ""
kubectl get hpa "$HPA_NAME" -n "$NAMESPACE"
echo ""
kubectl get pods -n "$NAMESPACE" --no-headers | awk '{
  status=$3=="1/1"?"\033[32m✓\033[0m":"\033[33m⚠\033[0m"
  printf "    %s  %-40s  %s/%s\n", status, $1, $4, $5
}'
echo ""

INITIAL_REPLICAS=$(kubectl get hpa "$HPA_NAME" -n "$NAMESPACE" \
  -o jsonpath='{.status.currentReplicas}')
info "Replicas actuels    : ${BOLD}$INITIAL_REPLICAS${NC}"
info "Seuil scale-up CPU  : 50%"
info "maxReplicas         : $(kubectl get hpa $HPA_NAME -n $NAMESPACE \
  -o jsonpath='{.spec.maxReplicas}')"
info "Test prévu          : $REQUESTS requêtes, c=$CONCURRENCY (depuis $NODE)"

echo ""
read -r -p "  Appuyez sur [Entrée] pour lancer le test..." _

# =============================================================================
# PHASE 3 — Test de charge
# =============================================================================
phase "3/6 — Test de charge en cours"

info "Lancement ab sur $NODE → http://$APP_SVC_IP$ENDPOINT"
echo ""

# Lancer ab en arrière-plan sur node-1
ssh "$NODE" "ab -n $REQUESTS -c $CONCURRENCY \
  -H 'Accept-Encoding: gzip,deflate' \
  http://$APP_SVC_IP$ENDPOINT > /tmp/ab-result.txt 2>&1" &
AB_PID=$!
START_TS=$SECONDS

# Variables de suivi
SCALE_UP_DETECTED=false
SCALE_UP_TIME=""
MAX_REPLICAS_SEEN=$INITIAL_REPLICAS
PREV_REPLICAS=$INITIAL_REPLICAS

header
ELAPSED=0

while kill -0 $AB_PID 2>/dev/null; do
  sleep "$POLL"
  ELAPSED=$((SECONDS - START_TS))

  HPA_INFO=$(kubectl get hpa "$HPA_NAME" -n "$NAMESPACE" --no-headers 2>/dev/null || echo "")
  if [[ -z "$HPA_INFO" ]]; then
    echo "  [T+${ELAPSED}s] kubectl non disponible, retry..."
    continue
  fi

  CPU_RATIO=$(echo "$HPA_INFO" | awk '{print $3}')          # ex: 461%/50%
  REPLICAS=$(echo "$HPA_INFO"  | awk '{print $7}')           # ex: 4
  READY=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null \
    | grep -v mysql | awk '$2=="1/1"' | wc -l | tr -d ' ')
  TOTAL=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null \
    | grep -v mysql | wc -l | tr -d ' ')

  # Événements
  EVENT=""
  if [[ "$REPLICAS" -gt "$PREV_REPLICAS" ]]; then
    EVENT="${GREEN}▲ Scale-up ${PREV_REPLICAS}→${REPLICAS}${NC}"
    if [[ "$SCALE_UP_DETECTED" == false ]]; then
      SCALE_UP_DETECTED=true
      SCALE_UP_TIME=$ELAPSED
    fi
    PREV_REPLICAS=$REPLICAS
  elif [[ "$REPLICAS" -lt "$PREV_REPLICAS" ]]; then
    EVENT="${YELLOW}▼ Scale-down${NC}"
    PREV_REPLICAS=$REPLICAS
  fi

  [[ "$REPLICAS" -gt "$MAX_REPLICAS_SEEN" ]] && MAX_REPLICAS_SEEN=$REPLICAS

  printf "  %5ds  %-16s  %-10s  %s/%s" \
    "$ELAPSED" "$CPU_RATIO" "$REPLICAS" "$READY" "$TOTAL"
  [[ -n "$EVENT" ]] && printf "  $(echo -e "$EVENT")" || printf ""
  echo ""
done

wait $AB_PID || true   # ab peut finir avec code non-zero si erreurs HTTP
TOTAL_DURATION=$((SECONDS - START_TS))
echo ""
ok "Test de charge terminé (durée: ${TOTAL_DURATION}s)"

# =============================================================================
# PHASE 4 — Résultats ab
# =============================================================================
phase "4/6 — Résultats Apache Benchmark"

AB_OUTPUT=$(ssh "$NODE" "cat /tmp/ab-result.txt" 2>/dev/null || echo "")
if [[ -n "$AB_OUTPUT" ]]; then
  echo "$AB_OUTPUT" | grep -E \
    "^(Server Hostname|Document Path|Requests per second|Time taken|Complete requests|Failed requests|Non-2xx|Total transferred|50%|95%|99%)" \
    | sed 's/^/    /'
else
  warn "Résultats ab non disponibles"
fi

# =============================================================================
# PHASE 5 — Scale-down
# =============================================================================
if [[ "$SKIP_SCALEDOWN" != "true" ]]; then
  phase "5/6 — Attente du scale-down"
  info "Stabilisation: 120s minimum (stabilizationWindowSeconds)"
  info "Puis: -1 pod / 60s jusqu'à minReplicas ($INITIAL_REPLICAS)"
  echo ""

  WAIT_COUNT=0
  MAX_WAIT=20   # 20 × 30s = 10 minutes max

  while true; do
    CURRENT=$(kubectl get hpa "$HPA_NAME" -n "$NAMESPACE" \
      -o jsonpath='{.status.currentReplicas}' 2>/dev/null || echo "$MAX_REPLICAS_SEEN")
    CPU=$(kubectl get hpa "$HPA_NAME" -n "$NAMESPACE" --no-headers 2>/dev/null \
      | awk '{print $3}' || echo "?")

    printf "  [+%3ds]  CPU: %-12s  Replicas: %s\n" \
      "$((WAIT_COUNT * 30))" "$CPU" "$CURRENT"

    if [[ "$CURRENT" -le "$INITIAL_REPLICAS" ]]; then
      ok "Scale-down terminé — retour à $CURRENT replicas"
      break
    fi

    WAIT_COUNT=$((WAIT_COUNT + 1))
    if [[ $WAIT_COUNT -ge $MAX_WAIT ]]; then
      warn "Timeout 10min — scale-down toujours en cours ($CURRENT replicas)"
      break
    fi
    sleep 30
  done
fi

# =============================================================================
# PHASE 6 — Bilan
# =============================================================================
phase "6/6 — Bilan"
echo ""

FINAL_REPLICAS=$(kubectl get hpa "$HPA_NAME" -n "$NAMESPACE" \
  -o jsonpath='{.status.currentReplicas}' 2>/dev/null || echo "?")
PASS=true

# Scale-up
if [[ "$SCALE_UP_DETECTED" == true ]]; then
  ok "Scale-up détecté à T+${SCALE_UP_TIME}s : ${INITIAL_REPLICAS} → ${MAX_REPLICAS_SEEN} pods"
else
  warn "Aucun scale-up détecté"
  info "→ Vérifiez que CPU limit est défini sur le pod (kubectl describe pod)"
  info "→ Vérifiez le seuil HPA (kubectl describe hpa $HPA_NAME -n $NAMESPACE)"
  PASS=false
fi

# Scale-down
if [[ "$SKIP_SCALEDOWN" != "true" ]]; then
  if [[ "$FINAL_REPLICAS" -le "$INITIAL_REPLICAS" ]]; then
    ok "Scale-down terminé : retour à $FINAL_REPLICAS replicas"
  else
    warn "Scale-down en cours ($FINAL_REPLICAS replicas actuellement)"
    PASS=false
  fi
fi

# Stats générales
ok "Durée totale : ${TOTAL_DURATION}s"
info "Replicas max atteints : $MAX_REPLICAS_SEEN / $(kubectl get hpa $HPA_NAME -n $NAMESPACE \
  -o jsonpath='{.spec.maxReplicas}')"

# État HPA final
echo ""
echo "  État HPA final :"
kubectl get hpa "$HPA_NAME" -n "$NAMESPACE" | sed 's/^/    /'
echo ""
echo "  Pods actuels :"
kubectl get pods -n "$NAMESPACE" --no-headers | grep -v mysql | sed 's/^/    /'

echo ""
if [[ "$PASS" == true ]]; then
  echo -e "${GREEN}${BOLD}  ══════════════════════════════════${NC}"
  echo -e "${GREEN}${BOLD}   RÉSULTAT : SUCCÈS ✓              ${NC}"
  echo -e "${GREEN}${BOLD}  ══════════════════════════════════${NC}"
else
  echo -e "${YELLOW}${BOLD}  ══════════════════════════════════${NC}"
  echo -e "${YELLOW}${BOLD}   RÉSULTAT : PARTIEL / À VÉRIFIER  ${NC}"
  echo -e "${YELLOW}${BOLD}  ══════════════════════════════════${NC}"
fi
echo ""
