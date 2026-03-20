# Infrastructure Local-Lab
                         ┌──────────────────────┐
                         │       Internet       │
                         └──────────┬───────────┘
                                    │
                                    ▼
                         ┌──────────────────────┐
                         │   Ingress Controller │
                         │      (Pod)           │
                         │  on ingress-node     │
                         └──────────┬───────────┘
                                    │
                                    ▼
        ┌──────────────────────────────────────────────────┐
        │                Kubernetes Cluster                │
        │                                                  │
        │   ┌──────────────────────────────┐               │
        │   │ kube-1                       │               │
        │   │ control-plane + worker       │               │
        │   └──────────────┬───────────────┘               │
        │                  │                               │
        │   ┌──────────────▼───────────────┐               │
        │   │ kube-2                       │               │
        │   │ worker                       │               │
        │   └──────────────┬───────────────┘               │
        │                  │                               │
        │   ┌──────────────▼───────────────┐               │
        │   │ ingress-node                 │               │
        │   │ (labeled: ingress=true)      │               │
        │   │ runs ingress pod             │               │
        │   └──────────────┬───────────────┘               │
        │                  │                               │
        │   ┌──────────────▼───────────────┐               │
        │   │ monitoring-node              │               │
        │   │ (labeled: monitoring=true)   │               │
        │   │ runs Prometheus / Grafana    │               │
        │   │ Loki                         │               │
        │   └──────────────────────────────┘               │
        │                                                  │
        │   Workloads:                                     │
        │   - Application Pods                             │
        │   - Database Pods (with Persistent Volume)       │
        │                                                  │
        └──────────────────────────────────────────────────┘


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
    ├─ package application
    ├─ install via helm
    │
    ▼
[Phase 8] GitOps
    │
    ├─ create kustomize base
    ├─ create overlays (dev/prod)
    ├─ optional: ArgoCD
    │
    ▼
Automated deployment system

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
Kustomize / ArgoCD (automation)