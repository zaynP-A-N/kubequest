# ─────────────────────────────────────────────────────────────────────────────
# Loki Stack (collecte de logs)
#
# Différence métriques vs logs :
#
#   Prometheus = métriques = NOMBRES horodatés
#     ex: nombre de requêtes/sec, % CPU, latence p99
#     ➜ "Combien ?" → parfait pour les dashboards et alertes
#
#   Loki = logs = TEXTE horodaté
#     ex: "[ERROR] Database connection failed", "[INFO] User login: jeff@..."
#     ➜ "Pourquoi ?" → parfait pour le débogage
#
# Architecture Loki :
#
#   ┌──────────────────────────────────────────────┐
#   │  Chaque nœud                                  │
#   │  Promtail (DaemonSet) → lit /var/log/pods/   │
#   │                       → envoie à Loki        │
#   └──────────────────────────────────────────────┘
#                              │
#                              ▼
#                           Loki (stockage + indexation)
#                              │
#                              ▼
#                    Grafana (requêtes LogQL)
#
# DaemonSet = un pod sur CHAQUE nœud automatiquement.
#             Parfait pour la collecte de métriques/logs.
#
# LogQL = langage de requête de Loki (inspiré de PromQL)
#   Exemple : {namespace="production"} |= "ERROR" | last 1h
#
# Accès dans Grafana :
#   Sources de données → Loki → explorer les logs de n'importe quel pod
# ─────────────────────────────────────────────────────────────────────────────

resource "helm_release" "loki_stack" {
  name       = "loki-stack"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "loki-stack"
  namespace  = kubernetes_namespace.logging.metadata[0].name

  timeout = 300

  # Activer Promtail (agent de collecte sur chaque nœud)
  set {
    name  = "promtail.enabled"
    value = "true"
  }

  # Désactiver Grafana dans Loki (on utilise déjà Grafana dans monitoring)
  set {
    name  = "grafana.enabled"
    value = "false"
  }

  # Stockage persistant pour Loki
  set {
    name  = "loki.persistence.enabled"
    value = "true"
  }
  set {
    name  = "loki.persistence.storageClassName"
    value = "local-path"
  }
  set {
    name  = "loki.persistence.size"
    value = "5Gi"
  }

  # Rétention des logs : 7 jours
  set {
    name  = "loki.config.table_manager.retention_deletes_enabled"
    value = "true"
  }
  set {
    name  = "loki.config.table_manager.retention_period"
    value = "168h"
  }

  # Ressources adaptées au lab
  set {
    name  = "loki.resources.requests.memory"
    value = "128Mi"
  }
  set {
    name  = "loki.resources.limits.memory"
    value = "256Mi"
  }
}
