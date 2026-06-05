# Infrastructure Local-Lab
                         ┌──────────────────────┐
                         │       Internet       │
                         └──────────┬───────────┘
                                    │
                                    ▼
                         ┌──────────────────────┐
                         │   Ingress Controller │
                         │      (nginx pod)     │
                         │  on ingress-node     │
                         │  NodePort exposed    │
                         └──────────┬───────────┘
                                    │
                                    ▼
        ┌──────────────────────────────────────────────────────────┐
        │                  Kubernetes Cluster                      │
        │                                                          │
        │   ┌──────────────────────────────────────┐               │
        │   │ kube-1  (control-plane + worker)     │               │
        │   │  - API server, etcd, scheduler       │               │
        │   │  - ArgoCD (ns: argocd)               │               │
        │   │  - Sealed Secrets ctrl (kube-system) │               │
        │   └──────────────────┬───────────────────┘               │
        │                      │                                   │
        │   ┌──────────────────▼───────────────────┐               │
        │   │ kube-2  (worker)                     │               │
        │   │  - Laravel app pods  (ns: apphelm)   │               │
        │   │  - MySQL pod + PV    (ns: apphelm)   │               │
        │   └──────────────────┬───────────────────┘               │
        │                      │                                   │
        │   ┌──────────────────▼───────────────────┐               │
        │   │ ingress-node                         │               │
        │   │  - nginx ingress controller pod      │               │
        │   └──────────────────┬───────────────────┘               │
        │                      │                                   │
        │   ┌──────────────────▼───────────────────┐               │
        │   │ monitoring-node                      │               │
        │   │  - Prometheus + Grafana (monitoring) │               │
        │   │  - Loki (logs)                       │               │
        │   └──────────────────────────────────────┘               │
        │                                                          │
        └──────────────────────────────────────────────────────────┘


# Params of VMs
kube1, kube2 and monitoring: 4CPU, 4GRAM, 40G storage
ingress: 2CPU, 2GRAM, 20G storage

# Node's role
kube-1:
  role: control-plane

kube-2:
  role: worker

node-3:
  role: ingress

node-4:
  role: monitoring

# Phases based
[Phase 1] Infrastructure
    │
    ▼
Create 4 VM (local / AWS)
    │
    ▼
[Phase 2] Ansible (optional but recommended)
    │
    ├─ install containerd
    ├─ install kubeadm / kubelet / kubectl
    ├─ disable swap
    └─ system config
    │
    ▼
[Phase 3] Kubernetes Cluster (manual)
    │
    ├─ kubeadm init (kube-1)
    ├─ kubeadm join (other 3 nodes)
    ├─ kubectl get nodes
    └─ install CNI (Calico)
    │
    ▼
Cluster READY (4 nodes)
    │
    ▼
[Phase 4] Node Role Assignment
    │
    ├─ label ingress node
    ├─ label monitoring node
    │
    ▼
[Phase 5] Platform Deployment (manual)
    │
    ├─ deploy nginx ingress (nodeSelector)
    ├─ deploy Prometheus / Grafana
    ├─ deploy Loki
    ├─ deploy dashboard
    │
    ▼
[Phase 6] Application Deployment
    │
    ├─ convert docker-compose → k8s
    ├─ kubectl apply
    ├─ create service
    ├─ create ingress
    │
    ▼
Application accessible via Internet
    │
    ▼
[Phase 7] Helm                                          
    │
    ├─ helm/kubequest/ chart (Deployment, Service, Ingress,
    │   ConfigMap, SealedSecrets, PV/PVC, migration Job)
    ├─ values.yaml: image tag, replicas, ingress host,
    │   DB name/user, storage config
    ├─ migration Job as Helm hook (post-install/upgrade)
    │   with initContainer waiting for MySQL
    └─ deployed to namespace: apphelm
    │
    ▼
[Phase 8] GitOps                                        
    │
    ├─ ArgoCD installed (ns: argocd), exposed via NodePort
    ├─ Application CR (argocd/application.yaml):
    │   watches branch local-lab → path helm/kubequest/
    │   auto-sync: prune=true, selfHeal=true
    ├─ Sealed Secrets controller (kube-system)
    │   laravel-secret + mysql-secret sealed → committed to git
    │   no plaintext passwords anywhere in the repo
    └─ GitOps loop verified: git push → ArgoCD detects →
       applies to cluster automatically
    │
    ▼
Automated deployment system

# Namespaces
  app         - raw k8s manifests (Phase 6, kept as reference)
  apphelm     - Helm + ArgoCD managed app (Phase 7-8)
  argocd      - ArgoCD controllers + UI
  monitoring  - Prometheus, Grafana, Loki
  ingress-nginx - nginx ingress controller
  kube-system - CoreDNS, Sealed Secrets controller

# Tools
Terraform / VM
      │
      ▼
Ansible (optional)
      │
      ▼
kubeadm (create cluster)
      │
      ▼
kubectl / Helm (deploy resources)
      │
      ▼
ArgoCD + Sealed Secrets (GitOps + secret management)

# Key files
  helm/kubequest/          - Helm chart for the app
  argocd/application.yaml  - ArgoCD Application CR
  k8s/                     - original raw manifests (Phase 6)
  k8s/monitoring-values.yaml, loki-values.yaml - monitoring Helm values

# Optional (deferred)
  - Resource requests/limits on all pods
  - ResourceQuota per namespace
  - NetworkPolicy (restrict pod-to-pod traffic)

