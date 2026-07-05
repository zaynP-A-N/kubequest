# ─────────────────────────────────────────────────────────────────────────────
# kube-prometheus-stack
#
# Ce chart Helm installe TOUT en une fois :
#   - Prometheus       → collecte les métriques
#   - Grafana          → visualise les métriques (dashboards)
#   - Alertmanager     → gère les alertes (email, Slack, PagerDuty...)
#   - node-exporter    → métriques des nœuds (CPU, RAM, disque, réseau)
#   - kube-state-metrics → métriques des ressources K8s (pods, deployments...)
#   - CRDs             → PodMonitor, ServiceMonitor (pour ajouter ses propres métriques)
#
# Comment ça marche :
#
#   node-exporter (sur chaque nœud)  ─┐
#   kube-state-metrics               ─┤──► Prometheus (scrape toutes les 15s)
#   tes apps (si /metrics exposé)    ─┘         │
#                                               │ stocke dans TSDB (time-series DB)
#                                               ▼
#                                          Grafana (interroge Prometheus)
#                                               │
#                                               ▼
#                                          Dashboards (CPU, RAM, réseau, pods...)
#
# TSDB = Time Series Database : base de données optimisée pour les métriques
#         horodatées. Exemple : cpu_usage{pod="mon-pod"} 0.45 @ 1712345678
#
# Accès Grafana (après deploy) :
#   kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80
#   → http://localhost:3000
#   → admin / prom-operator (mot de passe configuré ci-dessous)
# ─────────────────────────────────────────────────────────────────────────────

resource "helm_release" "kube_prometheus_stack" {
  name       = "kube-prometheus-stack"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  namespace  = kubernetes_namespace.monitoring.metadata[0].name

  # Timeout plus long car ce chart télécharge beaucoup d'images
  timeout = 600

  # ── Grafana ────────────────────────────────────────────────────────────────
  set {
    name  = "grafana.adminPassword"
    value = "REDACTED_GRAFANA_PASSWORD"
  }
  set {
    name  = "grafana.resources.requests.memory"
    value = "128Mi"
  }
  set {
    name  = "grafana.resources.limits.memory"
    value = "256Mi"
  }

  # ── Prometheus ─────────────────────────────────────────────────────────────
  # Rétention des métriques : 7 jours (par défaut 10 jours, réduit pour le lab)
  set {
    name  = "prometheus.prometheusSpec.retention"
    value = "7d"
  }
  # Stockage persistant pour Prometheus (utilise notre StorageClass local-path)
  set {
    name  = "prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.storageClassName"
    value = "local-path"
  }
  set {
    name  = "prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.resources.requests.storage"
    value = "5Gi"
  }
  set {
    name  = "prometheus.prometheusSpec.resources.requests.memory"
    value = "512Mi"
  }
  set {
    name  = "prometheus.prometheusSpec.resources.limits.memory"
    value = "1Gi"
  }

  # ── Alertmanager ───────────────────────────────────────────────────────────
  set {
    name  = "alertmanager.alertmanagerSpec.resources.requests.memory"
    value = "64Mi"
  }
  set {
    name  = "alertmanager.alertmanagerSpec.resources.limits.memory"
    value = "128Mi"
  }
}
