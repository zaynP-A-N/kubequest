# =============================================================================
# Makefile — KubeQuest
# Interface unifiée pour toutes les opérations du projet
#
# Usage :
#   make help              → affiche cette aide
#   make install-cluster   → installe les 3 nœuds
#   make deploy-app        → déploie l'application (staging par défaut)
#   make deploy-monitoring → déploie Prometheus + Grafana
#   make status            → état complet du cluster
# =============================================================================

# Variables — à adapter à ton environnement
MASTER_IP   ?= $(shell kubectl get nodes -l node-role.kubernetes.io/control-plane \
                 -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)
ENV         ?= staging
HELM_DIR     = kubernetes/helm/kubequest-app
NAMESPACE    = $(shell [ "$(ENV)" = "production" ] && echo "app" || echo "staging")
RELEASE      = kubequest-$(ENV)

# Couleurs
GREEN  = \033[0;32m
YELLOW = \033[1;33m
CYAN   = \033[0;36m
NC     = \033[0m

.PHONY: help install-nodes init-master deploy-app deploy-monitoring \
        status logs clean rollback test-hpa

# ── Aide ──────────────────────────────────────────────────────────────────────
help:
	@echo ""
	@echo "  $(CYAN)KubeQuest — Commandes disponibles$(NC)"
	@echo ""
	@echo "  $(GREEN)Cluster$(NC)"
	@echo "    make install-nodes    Prépare les 3 VMs (install-node.sh)"
	@echo "    make init-master      Initialise le control-plane"
	@echo ""
	@echo "  $(GREEN)Application$(NC)"
	@echo "    make deploy-app       Déploie l'app (ENV=staging par défaut)"
	@echo "    make deploy-app ENV=production"
	@echo "    make rollback         Rollback Helm de l'app"
	@echo "    make clean            Supprime le déploiement"
	@echo ""
	@echo "  $(GREEN)Monitoring$(NC)"
	@echo "    make deploy-monitoring  Déploie Prometheus + Grafana"
	@echo ""
	@echo "  $(GREEN)Diagnostic$(NC)"
	@echo "    make status           État complet du cluster"
	@echo "    make logs             Logs de l'app (20 dernières lignes)"
	@echo "    make test-hpa         Simule une charge pour tester l'autoscaling"
	@echo ""

# ── Cluster ───────────────────────────────────────────────────────────────────
install-nodes:
	@echo "$(YELLOW)➜  Lance install-node.sh sur les 3 VMs...$(NC)"
	@echo "  ssh k8s-master  'bash -s' < kubernetes/scripts/install-node.sh"
	@echo "  ssh k8s-node01  'bash -s' < kubernetes/scripts/install-node.sh"
	@echo "  ssh k8s-node02  'bash -s' < kubernetes/scripts/install-node.sh"

init-master:
	@echo "$(YELLOW)➜  Initialisation du control-plane...$(NC)"
	bash kubernetes/scripts/init-master.sh

# ── Application ───────────────────────────────────────────────────────────────
deploy-app: _check-secrets
	@echo "$(YELLOW)➜  Déploiement de l'application en $(ENV)...$(NC)"
	helm upgrade --install $(RELEASE) $(HELM_DIR) \
		-f $(HELM_DIR)/values.yaml \
		-f $(HELM_DIR)/values-$(ENV).yaml \
		-f $(HELM_DIR)/values-secrets.yaml \
		--namespace $(NAMESPACE) \
		--create-namespace \
		--wait \
		--timeout 300s
	@echo "$(GREEN)✔  Déployé ! Accès : curl -H 'Host: app.kubequest.local' http://$(MASTER_IP):30080/api/counter/count$(NC)"

rollback:
	@echo "$(YELLOW)➜  Rollback de $(RELEASE)...$(NC)"
	helm rollback $(RELEASE) --namespace $(NAMESPACE)

clean:
	@echo "$(YELLOW)➜  Suppression du déploiement $(RELEASE)...$(NC)"
	helm uninstall $(RELEASE) --namespace $(NAMESPACE) || true

# ── Monitoring ────────────────────────────────────────────────────────────────
deploy-monitoring:
	@echo "$(YELLOW)➜  Déploiement Prometheus + Grafana...$(NC)"
	bash kubernetes/scripts/deploy-monitoring.sh

# ── Diagnostic ────────────────────────────────────────────────────────────────
status:
	@echo ""
	@echo "$(CYAN)=== Nœuds ===$(NC)"
	kubectl get nodes -o wide
	@echo ""
	@echo "$(CYAN)=== Pods (app) ===$(NC)"
	kubectl get pods -n $(NAMESPACE) -o wide 2>/dev/null || echo "Namespace $(NAMESPACE) non trouvé"
	@echo ""
	@echo "$(CYAN)=== Pods (monitoring) ===$(NC)"
	kubectl get pods -n monitoring -o wide 2>/dev/null || echo "Monitoring non déployé"
	@echo ""
	@echo "$(CYAN)=== Services ===$(NC)"
	kubectl get svc -n $(NAMESPACE) 2>/dev/null || true
	@echo ""
	@echo "$(CYAN)=== HPA ===$(NC)"
	kubectl get hpa -n $(NAMESPACE) 2>/dev/null || true
	@echo ""
	@echo "$(CYAN)=== Ingress ===$(NC)"
	kubectl get ingress -n $(NAMESPACE) 2>/dev/null || true

logs:
	kubectl logs -n $(NAMESPACE) -l app=laravel --tail=20 --prefix

test-hpa:
	@echo "$(YELLOW)➜  Simulation de charge pour tester le HPA...$(NC)"
	@echo "  Ctrl+C pour arrêter"
	kubectl run load-test --image=busybox --restart=Never -n $(NAMESPACE) -- \
		sh -c "while true; do wget -q -O- http://app/api/counter/count > /dev/null 2>&1; done" || true
	@echo "  Surveille avec : watch kubectl get hpa -n $(NAMESPACE)"

# ── Vérifications internes ────────────────────────────────────────────────────
_check-secrets:
	@test -f $(HELM_DIR)/values-secrets.yaml || \
		(echo "$(RED)✖  Fichier values-secrets.yaml manquant !$(NC)" && \
		 echo "  cp $(HELM_DIR)/values-secrets.yaml.example $(HELM_DIR)/values-secrets.yaml" && \
		 echo "  Puis édite le fichier avec tes vraies valeurs." && exit 1)
