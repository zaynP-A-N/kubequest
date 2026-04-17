# ─────────────────────────────────────────────────────────────────────────────
# Kubernetes Dashboard
#
# Interface graphique web du cluster.
# Permet de voir/modifier les ressources K8s sans utiliser kubectl.
#
# Utile pour :
#   - Visualiser les pods, services, deployments
#   - Voir les logs d'un pod
#   - Scaler un deployment
#   - Examiner les PVC, ConfigMaps, Secrets
#
# En prod : souvent désactivé ou très restreint (RBAC strict).
#           Les ingénieurs utilisent des outils comme Lens, k9s, ou Grafana.
# En lab : pratique pour voir l'état du cluster visuellement.
#
# Accès : via kubectl port-forward (tunnel local)
#   kubectl port-forward -n kubernetes-dashboard svc/kubernetes-dashboard-kong-proxy 8443:443
#   → https://localhost:8443
#
# Authentification : token d'un ServiceAccount admin
# ─────────────────────────────────────────────────────────────────────────────

resource "null_resource" "kubernetes_dashboard" {
  triggers = {
    version = "v2.7.0"
  }

  provisioner "local-exec" {
    command = "kubectl apply -f https://raw.githubusercontent.com/kubernetes/dashboard/v2.7.0/aio/deploy/recommended.yaml"
  }

  depends_on = [kubernetes_namespace.dashboard]
}

# ─────────────────────────────────────────────────────────────────────────────
# ServiceAccount admin pour le Dashboard
#
# Le Dashboard nécessite un token pour s'authentifier.
# On crée un ServiceAccount avec les droits cluster-admin (lab uniquement).
#
# En prod : on utilise OIDC (SSO d'entreprise) et des droits minimaux (RBAC).
# ─────────────────────────────────────────────────────────────────────────────

resource "kubernetes_service_account" "dashboard_admin" {
  metadata {
    name      = "dashboard-admin"
    namespace = kubernetes_namespace.dashboard.metadata[0].name
  }
}

resource "kubernetes_cluster_role_binding" "dashboard_admin" {
  metadata {
    name = "dashboard-admin"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "cluster-admin"
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.dashboard_admin.metadata[0].name
    namespace = kubernetes_namespace.dashboard.metadata[0].name
  }
}
