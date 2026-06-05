# KubeQuest — Local Kubernetes Lab (T-CLO-902-PAR_9)

A full local Kubernetes platform built from scratch: 4 VMs, kubeadm cluster, monitoring stack, a Laravel + MySQL application deployed via Helm, and GitOps automation with ArgoCD and Sealed Secrets.

---

## Table of Contents

1. [Architecture](#1-architecture)
2. [Prerequisites — Hardware](#2-prerequisites--hardware)
3. [Phase 1 — VM Preparation](#3-phase-1--vm-preparation)
4. [Phase 2 — Install Kubernetes packages on every node](#4-phase-2--install-kubernetes-packages-on-every-node)
5. [Phase 3 — Create the cluster](#5-phase-3--create-the-cluster)
6. [Phase 4 — Label the nodes](#6-phase-4--label-the-nodes)
7. [Phase 5 — Platform: Ingress + Monitoring](#7-phase-5--platform-ingress--monitoring)
8. [Phase 6 — Application: raw manifests (reference)](#8-phase-6--application-raw-manifests-reference)
9. [Phase 7 — Helm chart](#9-phase-7--helm-chart)
10. [Phase 8 — GitOps: ArgoCD + Sealed Secrets](#10-phase-8--gitops-argocd--sealed-secrets)
11. [Useful commands](#11-useful-commands)

---

## 1. Architecture

```
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
    │   │  - Prometheus + Grafana              │               │
    │   │  - Loki                              │               │
    │   └──────────────────────────────────────┘               │
    │                                                          │
    └──────────────────────────────────────────────────────────┘
```

**Namespaces:**

| Namespace | Contents |
|---|---|
| `apphelm` | Laravel app + MySQL (Helm managed, Phase 7-8) |
| `app` | Raw k8s manifests (Phase 6, kept as reference) |
| `argocd` | ArgoCD controllers + UI |
| `monitoring` | Prometheus, Grafana, Loki |
| `ingress-nginx` | nginx ingress controller |
| `kube-system` | CoreDNS, Sealed Secrets controller |

---

## 2. Prerequisites — Hardware

Create 4 VMs (local hypervisor or cloud). Recommended specs:

| Node | Role | vCPU | RAM | Disk |
|---|---|---|---|---|
| `kube-1` | control-plane + worker | 4 | 4 GB | 40 GB |
| `kube-2` | worker | 4 | 4 GB | 40 GB |
| `monitoring` | monitoring | 4 | 4 GB | 40 GB |
| `ingress` | ingress controller | 2 | 2 GB | 20 GB |

**OS:** Ubuntu 22.04 LTS on each VM.

Each VM must:
- Have a static IP or predictable hostname
- Be reachable from the others via SSH
- Have `/etc/hosts` entries for all nodes (so they can resolve each other by name)

Example `/etc/hosts` to add on **every** node:
```
192.168.175.133  kube1
192.168.175.134  kube2
192.168.175.135  monitoring
192.168.175.137  ingress
```
> Replace the IPs with your own VM IPs.

---

## 3. Phase 1 — VM Preparation

Run the following on **every node**.

### 3.1 Disable swap
Kubernetes requires swap to be off:
```bash
sudo swapoff -a
sudo sed -i '/ swap / s/^/#/' /etc/fstab
```

### 3.2 Load kernel modules
```bash
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter
```

### 3.3 Set sysctl parameters
```bash
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sudo sysctl --system
```

### 3.4 Install and configure containerd
```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg lsb-release containerd

sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml > /dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

sudo systemctl restart containerd
sudo systemctl enable containerd
```

Verify:
```bash
systemctl status containerd --no-pager
```

---

## 4. Phase 2 — Install Kubernetes packages on every node

Run on **every node**.

```bash
sudo apt-get update
sudo apt-get install -y apt-transport-https ca-certificates curl gpg

curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.30/deb/Release.key | \
  sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.30/deb/ /' | \
  sudo tee /etc/apt/sources.list.d/kubernetes.list

sudo apt-get update
sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl
```

---

## 5. Phase 3 — Create the cluster

### 5.1 Initialize the control-plane on kube-1
```bash
sudo kubeadm init --pod-network-cidr=192.168.0.0/16
```

Configure kubectl for your user:
```bash
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

### 5.2 Join the other nodes
On kube-1, get the join command:
```bash
kubeadm token create --print-join-command
```

Run the output of that command on **kube-2**, **ingress**, and **monitoring** (with `sudo`).

### 5.3 Install the CNI — Calico
Run on kube-1:
```bash
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/calico.yaml
```

Wait until all system pods are Running:
```bash
kubectl get pods -n kube-system -w
```

### 5.4 Verify
```bash
kubectl get nodes -o wide
```
All 4 nodes should show `Ready`.

---

## 6. Phase 4 — Label the nodes

Labels are used by `nodeSelector` in the Helm chart so pods land on the right nodes.

```bash
# Worker label (for app + MySQL pods)
kubectl label node kube2 node-role=worker

# Ingress label (for nginx ingress controller)
kubectl label node ingress node-role=ingress

# Monitoring label (for Prometheus/Grafana/Loki)
kubectl label node monitoring node-role=monitoring
```

Verify:
```bash
kubectl get nodes --show-labels
```

---

## 7. Phase 5 — Platform: Ingress + Monitoring

### 7.1 Install nginx Ingress Controller
```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update

helm upgrade --install ingress-ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --create-namespace \
  -f k8s/ingress-values.yaml
```

Verify:
```bash
kubectl get pods -n ingress-nginx
kubectl get svc -n ingress-nginx
```
Note the NodePort assigned to port 80 — that's how you access the app from outside.

### 7.2 Fix CoreDNS to resolve external domains
By default CoreDNS may fail to resolve external names (like github.com) in some VM setups. Patch it to use Google DNS:

```bash
kubectl patch configmap coredns -n kube-system --type merge -p \
  '{"data":{"Corefile":".:53 {\n    errors\n    health {\n       lameduck 5s\n    }\n    ready\n    kubernetes cluster.local in-addr.arpa ip6.arpa {\n       pods insecure\n       fallthrough in-addr.arpa ip6.arpa\n       ttl 30\n    }\n    prometheus :9153\n    forward . 8.8.8.8 8.8.4.4 {\n       max_concurrent 1000\n    }\n    cache 30 {\n       disable success cluster.local\n       disable denial cluster.local\n    }\n    loop\n    reload\n    loadbalance\n}\n"}}'

kubectl rollout restart deployment/coredns -n kube-system
```

### 7.3 Install Prometheus + Grafana
```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

kubectl create namespace monitoring

helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  -f k8s/monitoring-values.yaml
```

### 7.4 Install Loki
```bash
helm upgrade --install loki grafana/loki \
  --namespace monitoring \
  -f k8s/loki-values.yaml
```

Verify:
```bash
kubectl get pods -n monitoring
```

Get the Grafana admin password:
```bash
kubectl get secret -n monitoring monitoring-grafana \
  -o jsonpath="{.data.admin-password}" | base64 --decode && echo
```

---

## 8. Phase 6 — Application: raw manifests (reference)

> This phase is kept as a reference. The active deployment is Phase 7 (Helm). Skip to Phase 7 if you only want the Helm-managed version.

```bash
kubectl create namespace app
kubectl apply -f k8s/app/
kubectl get pods -n app -w
```

---

## 9. Phase 7 — Helm chart

The application (Laravel + MySQL) is packaged as a Helm chart in `helm/kubequest/`.

**What the chart deploys:**
- Laravel Deployment + Service
- MySQL Deployment + Service + PersistentVolume + PersistentVolumeClaim
- ConfigMap (non-secret env vars)
- SealedSecrets (encrypted credentials — see Phase 8)
- Nginx Ingress
- Migration Job (Helm hook: runs `php artisan migrate` after every install/upgrade, waits for MySQL with an initContainer)

### 9.1 Install the chart

```bash
helm upgrade --install kubequest helm/kubequest/ \
  --namespace apphelm \
  --create-namespace \
  --set mysql.storage.pvName=mysql-pv-helm \
  --set mysql.storage.hostPath=/mnt/data/mysql-helm \
  --set ingress.enabled=false
```

> `ingress.enabled=false` avoids a conflict if the `app` namespace already has an ingress on the same host. Set it to `true` and `--set ingress.host=apphelm.local` if you want a separate hostname.

Verify:
```bash
helm list -n apphelm
kubectl get pods -n apphelm -w
kubectl get jobs -n apphelm        # watch the migration hook
```

Access the app via port-forward:
```bash
kubectl port-forward svc/laravel-app -n apphelm 8080:80
# open http://localhost:8080
```

### 9.2 Upgrade (change image tag, replicas, etc.)
Edit `helm/kubequest/values.yaml` then:
```bash
helm upgrade kubequest helm/kubequest/ --namespace apphelm
```

Or without editing the file:
```bash
helm upgrade kubequest helm/kubequest/ --namespace apphelm --set app.replicas=2
```

---

## 10. Phase 8 — GitOps: ArgoCD + Sealed Secrets

### 10.1 Install ArgoCD
```bash
kubectl create namespace argocd
kubectl apply -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

kubectl get pods -n argocd -w
```

Wait until all 7 pods are Running.

### 10.2 Expose the ArgoCD UI via NodePort
```bash
kubectl patch svc argocd-server -n argocd \
  -p '{"spec": {"type": "NodePort"}}'

kubectl get svc argocd-server -n argocd
```

Note the NodePort mapped to 443. Access the UI at `https://<any-node-ip>:<nodeport>`.

Get the initial admin password:
```bash
kubectl get secret argocd-initial-admin-secret -n argocd \
  -o jsonpath="{.data.password}" | base64 -d && echo
```

Login with username `admin` and the password above. Change it immediately in the UI (User Info → Update Password).

### 10.3 Add GitHub credentials (required for private repos)

Create a GitHub Personal Access Token (PAT) at `https://github.com/settings/tokens` with `repo` scope.

> If your GitHub organization uses SAML SSO, go to `https://github.com/settings/tokens`, find your token, click **Configure SSO**, and authorize the organization.

```bash
kubectl create secret generic github-repo \
  --namespace argocd \
  --from-literal=type=git \
  --from-literal=url=https://github.com/EpitechMscProPromo2026/T-CLO-902-PAR_9.git \
  --from-literal=username=git \
  --from-literal=password=<YOUR_GITHUB_PAT>

kubectl label secret github-repo -n argocd \
  argocd.argoproj.io/secret-type=repository
```

### 10.4 Create the ArgoCD Application
```bash
kubectl apply -f argocd/application.yaml
```

This tells ArgoCD to:
- Watch branch `local-lab`, path `helm/kubequest/`
- Deploy to namespace `apphelm`
- Auto-sync on every push (prune + self-heal enabled)

Check sync status:
```bash
kubectl get application kubequest -n argocd
```

Status should reach `Synced / Healthy` within a few minutes.

### 10.5 Install Sealed Secrets controller
```bash
helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets
helm repo update

helm upgrade --install sealed-secrets sealed-secrets/sealed-secrets \
  --namespace kube-system

kubectl get pods -n kube-system -l app.kubernetes.io/name=sealed-secrets
```

### 10.6 Install kubeseal CLI (on your local machine)
```bash
wget -q https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.27.3/kubeseal-0.27.3-linux-amd64.tar.gz \
  -O /tmp/kubeseal.tar.gz
tar -xzf /tmp/kubeseal.tar.gz -C /tmp kubeseal
sudo install -m 755 /tmp/kubeseal /usr/local/bin/kubeseal
kubeseal --version
```

### 10.7 Seal a secret and commit it

The Helm chart already has the SealedSecrets committed. To rotate or add a secret, regenerate and overwrite the file:

```bash
# Example: rotate the Laravel secret
kubectl create secret generic laravel-secret \
  --namespace apphelm \
  --dry-run=client \
  --from-literal=DB_PASSWORD="<new-password>" \
  --from-literal=APP_KEY="<app-key>" \
  -o yaml | kubeseal \
    --controller-name=sealed-secrets \
    --controller-namespace=kube-system \
    --format yaml > helm/kubequest/templates/sealed-laravel-secret.yaml

git add helm/kubequest/templates/sealed-laravel-secret.yaml
git commit -m "rotate: update laravel-secret"
git push origin local-lab
```

ArgoCD picks up the push → controller decrypts → real Secret updated in cluster.

> **Important:** Always include ALL keys when re-sealing. The SealedSecret replaces the entire Secret, not just one key.

### 10.8 Verify the full GitOps loop

1. Edit `helm/kubequest/values.yaml` — change `replicas: 1` to `replicas: 2`
2. Commit and push
3. Wait ~3 min or click **Refresh** in the ArgoCD UI
4. Watch the pod scale:
   ```bash
   kubectl get pods -n apphelm -w
   ```
5. Revert to `replicas: 1`, push again — pod scales back down

No `kubectl` or `helm` commands needed — git drives the cluster.

---

## 11. Useful commands

### Cluster health
```bash
kubectl get nodes -o wide
kubectl get pods -A
kubectl top nodes
```

### App
```bash
kubectl get pods -n apphelm
kubectl logs -n apphelm -l app=laravel-app
kubectl port-forward svc/laravel-app -n apphelm 8080:80
```

### Read a secret value from the cluster
```bash
kubectl get secret laravel-secret -n apphelm \
  -o jsonpath="{.data.DB_PASSWORD}" | base64 -d && echo
```

### ArgoCD
```bash
kubectl get application kubequest -n argocd
kubectl get application kubequest -n argocd -o wide   # shows sync revision
```

### Helm
```bash
helm list -A                        # all releases
helm history kubequest -n apphelm   # upgrade history
helm rollback kubequest 1 -n apphelm  # rollback to revision 1
```

### Debug a pod that won't start
```bash
kubectl describe pod <pod-name> -n <namespace>
kubectl logs <pod-name> -n <namespace>
kubectl logs <pod-name> -n <namespace> --previous   # if it crashed
```

### Grafana password
```bash
kubectl get secret -n monitoring monitoring-grafana \
  -o jsonpath="{.data.admin-password}" | base64 --decode && echo
```

---

## 12. Troubleshooting

### Sealed Secrets — operations

**Seal a new secret (create for the first time):**
```bash
kubectl create secret generic <secret-name> \
  --namespace <namespace> \
  --dry-run=client \
  --from-literal=KEY1="value1" \
  --from-literal=KEY2="value2" \
  -o yaml | kubeseal \
    --controller-name=sealed-secrets \
    --controller-namespace=kube-system \
    --format yaml > helm/kubequest/templates/sealed-<secret-name>.yaml
```

**Rotate / change a password (re-seal with new value):**
```bash
# Always include ALL keys, not just the one you're changing
kubectl create secret generic laravel-secret \
  --namespace apphelm \
  --dry-run=client \
  --from-literal=DB_PASSWORD="my-new-password" \
  --from-literal=APP_KEY="base64:xxxx" \
  -o yaml | kubeseal \
    --controller-name=sealed-secrets \
    --controller-namespace=kube-system \
    --format yaml > helm/kubequest/templates/sealed-laravel-secret.yaml

git add helm/kubequest/templates/sealed-laravel-secret.yaml
git commit -m "rotate: update DB_PASSWORD"
git push origin local-lab
# ArgoCD auto-syncs → controller decrypts → real Secret updated
```

**Read (decrypt) a secret value from the cluster:**
```bash
# Read DB_PASSWORD
kubectl get secret laravel-secret -n apphelm \
  -o jsonpath="{.data.DB_PASSWORD}" | base64 -d && echo

# Read APP_KEY
kubectl get secret laravel-secret -n apphelm \
  -o jsonpath="{.data.APP_KEY}" | base64 -d && echo

# Read MySQL root password
kubectl get secret mysql-secret -n apphelm \
  -o jsonpath="{.data.MYSQL_ROOT_PASSWORD}" | base64 -d && echo

# List all keys in a secret (without values)
kubectl get secret laravel-secret -n apphelm -o jsonpath="{.data}" | python3 -m json.tool
```

**Check if the SealedSecret was successfully decrypted:**
```bash
kubectl get sealedsecret -n apphelm
# SYNCED=True means the controller successfully created the real Secret
```

**SealedSecret shows SYNCED=False — why?**
```bash
kubectl describe sealedsecret laravel-secret -n apphelm
# Common cause: the SealedSecret was sealed for a different namespace or cluster.
# Fix: re-seal targeting the correct namespace (--namespace must match).
```

---

### Helm — common operations

**Preview what a helm upgrade will change (dry run):**
```bash
helm upgrade kubequest helm/kubequest/ --namespace apphelm --dry-run
```

**Upgrade with a values override:**
```bash
# Change image tag
helm upgrade kubequest helm/kubequest/ --namespace apphelm --set app.image.tag=v2

# Change replicas
helm upgrade kubequest helm/kubequest/ --namespace apphelm --set app.replicas=3

# Use a custom values file (e.g. for prod)
helm upgrade kubequest helm/kubequest/ --namespace apphelm -f my-prod-values.yaml
```

**See the full upgrade history:**
```bash
helm history kubequest -n apphelm
```

**Rollback to a previous revision:**
```bash
helm rollback kubequest 2 -n apphelm   # rollback to revision 2
helm rollback kubequest 0 -n apphelm   # 0 = previous revision
```

**See the rendered YAML Helm would apply:**
```bash
helm template kubequest helm/kubequest/ --namespace apphelm
```

**Uninstall a release (deletes all its resources):**
```bash
helm uninstall kubequest -n apphelm
```

**Helm upgrade fails because a resource already exists:**
This happens when a resource was created outside of Helm. Force Helm to take ownership:
```bash
helm upgrade --install kubequest helm/kubequest/ --namespace apphelm \
  --force
```

---

### ArgoCD — common situations

**Sync is stuck on Unknown:**
```bash
# Check repo-server can reach GitHub
kubectl exec -n argocd deployment/argocd-repo-server -- \
  sh -c "getent hosts github.com || echo DNS_FAIL"

# If DNS_FAIL → patch CoreDNS (see Phase 5 section 7.2)

# Check for auth errors
kubectl logs -n argocd deployment/argocd-repo-server --tail=20
```

**App is OutOfSync but won't sync automatically:**
```bash
# Force a manual sync
kubectl patch application kubequest -n argocd \
  --type merge -p '{"operation": {"initiatedBy": {"username": "admin"}, "sync": {"revision": "HEAD"}}}'

# Or click Sync → Synchronize in the UI
```

**App shows Degraded health:**
```bash
# Find which resource is unhealthy
kubectl get application kubequest -n argocd -o yaml | grep -A 10 "health:"

# Then check that specific resource
kubectl describe <resource-type> <resource-name> -n apphelm
```

**ArgoCD forgot the GitHub credentials after a restart:**
```bash
kubectl get secret github-repo -n argocd
# If missing, re-create it (see Phase 8 section 10.3)
```

---

### Pods — common issues

**Pod stuck in Pending:**
```bash
kubectl describe pod <pod-name> -n <namespace>
# Look at Events section at the bottom
# Common causes:
#   - No node matches nodeSelector → check node labels
#   - PVC not bound → check PV/PVC status
#   - Insufficient resources → check node capacity
```

**Pod in CrashLoopBackOff:**
```bash
kubectl logs <pod-name> -n <namespace>
kubectl logs <pod-name> -n <namespace> --previous  # logs from last crash
kubectl describe pod <pod-name> -n <namespace>     # check exit code
```

**Pod in ImagePullBackOff:**
```bash
kubectl describe pod <pod-name> -n <namespace>
# Look for: "Failed to pull image" in Events
# Common causes: wrong image name/tag, private registry without imagePullSecret
```

**Migration Job failed:**
```bash
kubectl get jobs -n apphelm
kubectl logs -n apphelm -l job-name=app-migration
# Common causes:
#   - MySQL not ready yet (initContainer should handle this, but check its logs)
#   - Wrong DB credentials (check the SealedSecret was decrypted correctly)
```

---

### PersistentVolume issues

**PVC stuck in Pending:**
```bash
kubectl get pv
kubectl get pvc -n apphelm
kubectl describe pvc mysql-pvc -n apphelm
# Common cause: PV name mismatch or PV already Bound to another PVC
```

**PV is Released but you want to reuse it:**
```bash
# A Retain PV keeps data after its PVC is deleted. To rebind:
kubectl patch pv mysql-pv-helm \
  -p '{"spec":{"claimRef": null}}'
# Now it's Available and a new PVC can bind to it
```

---

### DNS issues inside the cluster

**Pod can't resolve external hostnames (e.g. github.com):**
```bash
# Test from inside the cluster
kubectl run dns-test --image=busybox:1.28 --restart=Never --rm \
  -- sh -c "nslookup github.com"

# If it fails, patch CoreDNS to use 8.8.8.8 (see Phase 5 section 7.2)
```

**Pod can't resolve a service in another namespace:**
```bash
# Use the fully qualified name: <service>.<namespace>.svc.cluster.local
# Example: mysql.apphelm.svc.cluster.local
kubectl run dns-test --image=busybox:1.28 --restart=Never --rm \
  -- sh -c "nslookup mysql.apphelm.svc.cluster.local"
```

---

### Ingress issues

**Two Ingresses with same host rejected by webhook:**
```
admission webhook "validate.nginx.ingress.kubernetes.io" denied the request:
host "app.local" and path "/" is already defined in ingress app/app-ingress
```
Fix: use a different host for the second Ingress:
```bash
helm upgrade kubequest helm/kubequest/ --namespace apphelm \
  --set ingress.host=apphelm.local
```
Or disable the Ingress entirely and use port-forward instead:
```bash
helm upgrade kubequest helm/kubequest/ --namespace apphelm \
  --set ingress.enabled=false
```

**Ingress returns 404 or 502:**
```bash
# Check the ingress controller logs
kubectl logs -n ingress-nginx -l app.kubernetes.io/name=ingress-nginx --tail=30

# Check the ingress resource is correct
kubectl describe ingress app-ingress -n apphelm

# Check the backend service and pods are healthy
kubectl get svc laravel-app -n apphelm
kubectl get endpoints laravel-app -n apphelm
```
