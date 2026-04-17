# ─────────────────────────────────────────────────────────────────────────────
# Namespaces
#
# Un namespace = espace de noms isolé dans le cluster.
# C'est comme un "dossier" qui regroupe les ressources d'un même service.
#
# Avantages :
#   - Isolation (un pod dans "monitoring" ne voit pas "logging" par défaut)
#   - Quota de ressources par namespace
#   - RBAC par namespace (droits différents par équipe)
#
# En prod, on a souvent : dev, staging, production, monitoring, logging...
# ─────────────────────────────────────────────────────────────────────────────

resource "kubernetes_namespace" "ingress_nginx" {
  metadata {
    name = "ingress-nginx"
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }
}

resource "kubernetes_namespace" "monitoring" {
  metadata {
    name = "monitoring"
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }
}

resource "kubernetes_namespace" "logging" {
  metadata {
    name = "logging"
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }
}

resource "kubernetes_namespace" "dashboard" {
  metadata {
    name = "kubernetes-dashboard"
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }
}
