# ─────────────────────────────────────────────────────────────────────────────
# NGINX Ingress Controller
#
# Problème sans Ingress :
#   Pour exposer un service K8s à l'extérieur, on a 2 options basiques :
#   - NodePort    → un port fixe sur CHAQUE nœud (ex: nodeIP:30080)
#   - LoadBalancer → crée un LB cloud (AWS ALB) → pas dispo en lab kubeadm
#
#   Sans Ingress, chaque service a son propre port aléatoire → ingérable.
#
# Ce que fait l'Ingress Controller :
#   - UN seul point d'entrée HTTP/HTTPS (port 80/443)
#   - Routage basé sur le nom de domaine ou le chemin URL
#   - Terminaison TLS (certificats SSL)
#
#   Exemple :
#     grafana.kubequest.local  → Service grafana:3000
#     dashboard.kubequest.local → Service dashboard:443
#     app.kubequest.local      → Service mon-app:8080
#
# Pourquoi NGINX ?
#   nginx-ingress  → le plus utilisé, battle-tested, simple
#   traefik        → auto-découverte, bonne DX, populaire avec K3s
#   haproxy        → très haute performance, enterprise
#   aws-alb        → natif AWS, intégration IAM → requis sur EKS prod
#
# En lab : NodePort (pas de LoadBalancer AWS disponible)
#   HTTP  → port 30080 sur tous les nœuds
#   HTTPS → port 30443 sur tous les nœuds
# ─────────────────────────────────────────────────────────────────────────────

resource "helm_release" "ingress_nginx" {
  name       = "ingress-nginx"
  repository = "https://kubernetes.github.io/ingress-nginx"
  chart      = "ingress-nginx"
  namespace  = kubernetes_namespace.ingress_nginx.metadata[0].name

  # En lab : NodePort au lieu de LoadBalancer
  set {
    name  = "controller.service.type"
    value = "NodePort"
  }
  set {
    name  = "controller.service.nodePorts.http"
    value = "30080"
  }
  set {
    name  = "controller.service.nodePorts.https"
    value = "30443"
  }

  # Classe d'Ingress : chaque Ingress resource doit référencer cette classe
  set {
    name  = "controller.ingressClassResource.default"
    value = "true"
  }

  # Limites ressources adaptées aux t4g.medium (2 vCPU, 4GB RAM)
  set {
    name  = "controller.resources.requests.memory"
    value = "128Mi"
  }
  set {
    name  = "controller.resources.requests.cpu"
    value = "100m"
  }
  set {
    name  = "controller.resources.limits.memory"
    value = "256Mi"
  }
}
