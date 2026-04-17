terraform {
  required_version = ">= 1.5"

  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.27"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.13"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# Provider Kubernetes
# Se connecte au cluster en lisant ~/.kube/config (même config que kubectl)
# Le tunnel SSH doit être actif avant tout terraform plan/apply
# ─────────────────────────────────────────────────────────────────────────────
provider "kubernetes" {
  config_path    = pathexpand("~/.kube/config")
  config_context = "kubernetes-admin@kubernetes"
}

# ─────────────────────────────────────────────────────────────────────────────
# Provider Helm
# Helm est le gestionnaire de paquets Kubernetes — comme apt pour Linux
# Il déploie des "charts" (packages de manifests K8s pré-configurés)
# ─────────────────────────────────────────────────────────────────────────────
provider "helm" {
  kubernetes {
    config_path    = pathexpand("~/.kube/config")
    config_context = "kubernetes-admin@kubernetes"
  }
}
