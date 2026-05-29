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



Saved to project memory, so next time you open Claude here it'll already know where you are. Now here's your
  pickup material for next session.

  📋 Copy-paste prompt for next time

  ▎ I'm on the KubeQuest project (T-CLO-902-PAR_9). Phases 1–6 are done and the DB config is fixed. Today I 
  ▎ want to do Phase 7 — Helm: package everything in k8s/app/ into a Helm chart. Then later Phase 8 — GitOps 
  ▎ with ArgoCD + Sealed Secrets. Check the memory for context, then start Phase 7.

  ---
  Phase 7 — Helm checklist

  - [ ] Create chart skeleton: helm/kubequest/ with Chart.yaml, values.yaml, templates/
  - [ ] Templatize the existing manifests (Laravel Deployment+Service, MySQL PV/PVC/Secret/Deployment+Service,
  ConfigMap, Ingress, migration Job)
  - [ ] Move to values.yaml: image repo + tag, replica count, ingress host (app.local), DB name/user/password,
  storage size
  - [ ] Keep the DB password injectable (--set / values), not hardcoded → ready for Sealed Secrets
  - [ ] Migration Job as a Helm hook (post-install,post-upgrade) so it runs automatically
  - [ ] Test: helm lint, then helm upgrade --install kubequest helm/kubequest -n app --create-namespace
  - [ ] Verify pods/ingress, then helm template to confirm output matches old manifests

  Phase 8 — GitOps (ArgoCD) checklist

  - [ ] Install Argo CD (kubectl create ns argocd + official manifests or Helm)
  - [ ] Access the Argo CD UI (port-forward or an ingress) and get the initial admin password
  - [ ] Create an Application CR pointing at this git repo → path helm/kubequest
  - [ ] Set sync policy to automated (prune + self-heal) and confirm it syncs
  - [ ] Install Sealed Secrets controller, kubeseal your DB secret, commit the encrypted SealedSecret, remove
  the plaintext secret from the chart
  - [ ] Verify: change a value in git → Argo auto-syncs the cluster
  - [ ] (optional) Kustomize dev/prod overlays as in your architecture diagram

  ---