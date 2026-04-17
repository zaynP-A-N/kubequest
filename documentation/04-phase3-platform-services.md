# Phase 3 — Services Plateforme

---

## Ce qu'on a fait

1. Créé la structure Terraform `terraform/platform/` pour gérer le cluster via code
2. Installé `local-path-provisioner` — stockage persistant pour le lab
3. Déployé `NGINX Ingress Controller` — routeur HTTP/HTTPS du cluster
4. Déployé `Kubernetes Dashboard` — interface graphique du cluster
5. Déployé `kube-prometheus-stack` — Prometheus + Grafana + Alertmanager
6. Déployé `Loki + Promtail` — collecte centralisée des logs

**Résultat** : cluster observable (métriques + logs), accessible via des UIs web.

---

## Pourquoi Terraform et pas `helm install` directement ?

On aurait pu faire :
```bash
helm install ingress-nginx ingress-nginx/ingress-nginx -n ingress-nginx
helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack -n monitoring
# etc.
```

Mais on a choisi Terraform pour plusieurs raisons :

```
helm install (impératif)          terraform apply (déclaratif)
─────────────────────────         ──────────────────────────────
"installe ce chart"               "l'état désiré est ce fichier .tf"
pas de trace de l'état            état stocké dans terraform.tfstate
difficile à reproduire            100% reproductible
pas de diff avant apply           terraform plan montre les changements
si raté : état inconnu            si raté : terraform destroy propre
```

**En entreprise** : toute la config plateforme est dans Git sous forme de Terraform.
Un ingénieur qui rejoint l'équipe fait `terraform apply` et obtient
exactement le même environnement que ses collègues.

---

## Architecture finale de Phase 3

```
Internet (ou ton Mac)
        │
        │  port 30080 (HTTP) / 30443 (HTTPS)
        ▼
┌───────────────────────────────────────────────────────────────┐
│                   NGINX Ingress Controller                     │
│           namespace: ingress-nginx                             │
│   "le routeur HTTP — distribue le trafic selon le domaine"     │
└──────────────┬────────────────────┬──────────────────────────┘
               │                    │
               ▼                    ▼
        Grafana :3000         Dashboard :8443
        (monitoring)          (kubernetes-dashboard)
               │
               ▼
     ┌─────────┴──────────────────────┐
     │         namespace: monitoring   │
     │                                 │
     │  Prometheus ←── node-exporter   │
     │      │     ←── kube-state-metrics│
     │      │     ←── tes apps (/metrics)│
     │      ↓                          │
     │  Grafana (dashboards)           │
     │  Alertmanager (alertes)         │
     └─────────────────────────────────┘

     ┌─────────────────────────────────┐
     │         namespace: logging      │
     │                                 │
     │  Promtail (DaemonSet)           │
     │  lit /var/log/pods/ sur         │
     │  CHAQUE nœud → envoie à Loki   │
     │                                 │
     │  Loki (stockage + index)        │
     │  ← interrogé par Grafana        │
     └─────────────────────────────────┘
```

---

## Vérification préalable — Le cluster est-il vivant ?

Avant toute installation, on a vérifié l'état du cluster :

```bash
# Depuis node-1 directement via SSH
ssh node-1 "kubectl get nodes"
```

Résultat attendu :
```
NAME                                           STATUS   ROLES                  AGE    VERSION
ip-10-2-53-35.eu-central-1.compute.internal    Ready    control-plane,worker   101m   v1.29.15
ip-10-2-53-34.eu-central-1.compute.internal    Ready    worker                 99m    v1.29.15
ip-10-2-53-69.eu-central-1.compute.internal    Ready    worker                 99m    v1.29.15
ip-10-2-53-145.eu-central-1.compute.internal   Ready    worker                 99m    v1.29.15
```

```bash
# Ouvrir le tunnel SSH pour kubectl depuis le Mac
bash kubernetes/scripts/tunnel.sh start

# Vérifier l'accès depuis le Mac
kubectl get nodes
```

---

## Étape 0 — Structure Terraform

```bash
mkdir -p terraform/platform
```

### `terraform/platform/main.tf` — les providers

```hcl
terraform {
  required_version = ">= 1.5"
  required_providers {
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.27" }
    helm       = { source = "hashicorp/helm",       version = "~> 2.13" }
    null       = { source = "hashicorp/null",       version = "~> 3.2"  }
  }
}

provider "kubernetes" {
  config_path    = "~/.kube/config"
  config_context = "kubernetes-admin@kubernetes"
}

provider "helm" {
  kubernetes {
    config_path    = "~/.kube/config"
    config_context = "kubernetes-admin@kubernetes"
  }
}
```

**`config_context`** : le nom du contexte dans `~/.kube/config`.
Pour le trouver : `kubectl config get-contexts` → colonne NAME.

```bash
# Initialiser Terraform (télécharge les providers)
cd terraform/platform
terraform init
```

Résultat :
```
Installed hashicorp/kubernetes v2.38.0
Installed hashicorp/helm v2.17.0
Installed hashicorp/null v3.2.4
Terraform has been successfully initialized!
```

---

## Étape 1 — Namespaces

### Concept : qu'est-ce qu'un namespace ?

```
Un namespace = "dossier" dans Kubernetes.

Sans namespaces :
  - Tous les pods dans "default"
  - Impossible de savoir ce qui appartient à quoi
  - Pas de limitation de ressources par service

Avec namespaces :
  ┌─────────────────────────────────────────────┐
  │  default          → tes apps métier          │
  │  ingress-nginx    → routeur HTTP             │
  │  monitoring       → Prometheus + Grafana     │
  │  logging          → Loki + Promtail          │
  │  kubernetes-dashboard → UI du cluster        │
  │  kube-system      → composants K8s internes  │
  └─────────────────────────────────────────────┘

Avantages :
  - kubectl get pods -n monitoring → uniquement les pods monitoring
  - Quota CPU/RAM par namespace
  - RBAC : l'équipe dev n'a pas accès au namespace monitoring
  - NetworkPolicy : bloquer le trafic entre namespaces
```

### `terraform/platform/namespaces.tf`

```hcl
resource "kubernetes_namespace" "ingress_nginx" {
  metadata {
    name = "ingress-nginx"
    labels = { "app.kubernetes.io/managed-by" = "terraform" }
  }
}
# + monitoring, logging, kubernetes-dashboard
```

```bash
# Voir le plan avant d'appliquer (TOUJOURS faire ça en prod)
terraform plan
```

Résultat du plan :
```
Plan: 5 to add, 0 to change, 0 to destroy.
  + kubernetes_namespace.dashboard        → kubernetes-dashboard
  + kubernetes_namespace.ingress_nginx    → ingress-nginx
  + kubernetes_namespace.logging         → logging
  + kubernetes_namespace.monitoring      → monitoring
  + null_resource.local_path_provisioner → storage
```

`terraform plan` = "montre-moi ce que tu vas faire SANS le faire".  
C'est l'équivalent d'un `git diff` avant un `git commit`.

```bash
terraform apply -auto-approve
```

Vérification :
```bash
kubectl get namespaces | grep -E "ingress|monitoring|logging|dashboard|local-path"
```
```
ingress-nginx          Active
kubernetes-dashboard   Active
local-path-storage     Active
logging                Active
monitoring             Active
```

---

## Étape 2 — Storage (local-path-provisioner)

### Problème : les PVC restent en Pending sans provisioner

En Kubernetes, un **PVC** (PersistentVolumeClaim) = une demande de stockage :
```yaml
# Un pod dit : "j'ai besoin de 5Gi de stockage"
kind: PersistentVolumeClaim
spec:
  resources:
    requests:
      storage: 5Gi
```

Pour satisfaire cette demande, K8s a besoin d'un **provisioner** :
- Sur EKS (prod) → le provisioner EBS d'AWS crée automatiquement un disque AWS
- Sur kubeadm (lab) → **aucun provisioner par défaut** → le PVC reste `Pending` pour toujours

### Solution : local-path-provisioner (Rancher)

```
Demande PVC 5Gi
        │
        ▼
local-path-provisioner
        │
        ▼
crée /opt/local-path-provisioner/<nom-pvc>/ sur le nœud
        │
        ▼
PVC passe de Pending → Bound
        │
        ▼
le pod peut démarrer
```

**Limitation** : les données sont sur **un seul nœud**. Si ce nœud tombe, les données sont perdues. Acceptable en lab, jamais en prod.

### `terraform/platform/storage.tf`

```hcl
resource "null_resource" "local_path_provisioner" {
  # Installe le provisioner
  provisioner "local-exec" {
    command = "kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.28/deploy/local-path-storage.yaml"
  }
  # Le marque comme StorageClass par défaut
  provisioner "local-exec" {
    command = "kubectl patch storageclass local-path -p '{\"metadata\": {\"annotations\":{\"storageclass.kubernetes.io/is-default-class\":\"true\"}}}'"
  }
}
```

**`null_resource`** : ressource Terraform qui n'existe pas dans K8s — elle sert uniquement à exécuter des commandes shell (`local-exec`).

Vérification :
```bash
kubectl get storageclass
```
```
NAME                   PROVISIONER             VOLUMEBINDINGMODE
local-path (default)   rancher.io/local-path   WaitForFirstConsumer
```

`(default)` = tout PVC sans `storageClassName` explicite utilisera `local-path`.

---

## Étape 3 — NGINX Ingress Controller

### Problème : comment exposer plusieurs services sur le port 80 ?

Sans Ingress, pour accéder à Grafana et au Dashboard :
```
Grafana   → nodeIP:31234  (NodePort aléatoire)
Dashboard → nodeIP:32891  (NodePort aléatoire)
```
Impossible à retenir et à gérer.

Avec Ingress :
```
grafana.kubequest.local   → port 80 → Grafana
dashboard.kubequest.local → port 80 → Dashboard
```

Un seul point d'entrée, routage par nom de domaine.

### Comment fonctionne l'Ingress

```
                    ┌──────────────────────────────┐
HTTP request        │    NGINX Ingress Controller   │
Host: grafana.kube  │                               │
───────────────────►│  lit les ressources Ingress   │
                    │  dans tout le cluster         │
                    │                               │
                    │  if Host == grafana.kube      │
                    │    → forward to grafana:80    │
                    │  if Host == dashboard.kube    │
                    │    → forward to dashboard:443 │
                    └──────────────┬────────────────┘
                                   │
                          ┌────────┴────────┐
                          ▼                 ▼
                     Grafana pod      Dashboard pod
```

### `terraform/platform/ingress.tf`

```hcl
resource "helm_release" "ingress_nginx" {
  name       = "ingress-nginx"
  repository = "https://kubernetes.github.io/ingress-nginx"
  chart      = "ingress-nginx"
  namespace  = "ingress-nginx"

  # Lab : NodePort (pas de LoadBalancer AWS disponible)
  set { name = "controller.service.type",            value = "NodePort" }
  set { name = "controller.service.nodePorts.http",  value = "30080"   }
  set { name = "controller.service.nodePorts.https", value = "30443"   }

  # IngressClass par défaut (toutes les ressources Ingress l'utilisent)
  set { name = "controller.ingressClassResource.default", value = "true" }
}
```

```bash
terraform apply -auto-approve
# Durée : ~40 secondes (téléchargement de l'image NGINX)
```

Vérification :
```bash
kubectl get pods -n ingress-nginx
kubectl get svc -n ingress-nginx
```
```
NAME                                        READY   STATUS    RESTARTS
ingress-nginx-controller-64c797bb77-pvmzd   1/1     Running   0

NAME                       TYPE       PORT(S)
ingress-nginx-controller   NodePort   80:30080/TCP,443:30443/TCP
```

**En prod AWS** : `type: LoadBalancer` crée automatiquement un AWS ALB avec une IP publique fixe et du TLS géré par ACM (AWS Certificate Manager).

---

## Étape 4 — Kubernetes Dashboard

### À quoi ça sert ?

```
Interface web pour :
  - Voir tous les pods, services, deployments
  - Consulter les logs d'un pod sans kubectl
  - Scaler un deployment (augmenter le nombre de réplicas)
  - Voir les ressources consommées (CPU/RAM)
  - Inspecter les ConfigMaps et Secrets (masqués)
```

### `terraform/platform/dashboard.tf`

```hcl
# Installation via manifest officiel
resource "null_resource" "kubernetes_dashboard" {
  provisioner "local-exec" {
    command = "kubectl apply -f https://raw.githubusercontent.com/kubernetes/dashboard/v2.7.0/aio/deploy/recommended.yaml"
  }
}

# ServiceAccount avec droits admin (lab uniquement)
resource "kubernetes_service_account" "dashboard_admin" {
  metadata {
    name      = "dashboard-admin"
    namespace = "kubernetes-dashboard"
  }
}

resource "kubernetes_cluster_role_binding" "dashboard_admin" {
  metadata { name = "dashboard-admin" }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "cluster-admin"        # droits totaux sur tout le cluster
  }
  subject {
    kind      = "ServiceAccount"
    name      = "dashboard-admin"
    namespace = "kubernetes-dashboard"
  }
}
```

**`ClusterRoleBinding`** = attache un rôle à un utilisateur/compte de service.
`cluster-admin` = droits totaux — acceptable en lab, dangereux en prod.

**En prod** : droits minimaux par équipe (RBAC), authentification OIDC (SSO).

### Accéder au Dashboard

```bash
# Port-forward vers le service dashboard
kubectl port-forward -n kubernetes-dashboard svc/kubernetes-dashboard 8443:443

# Ouvre dans le navigateur : https://localhost:8443
# (accepter le certificat auto-signé)
```

```bash
# Générer le token d'authentification
kubectl create token dashboard-admin -n kubernetes-dashboard --duration=24h
```

Copie le token affiché → colle-le dans le champ "Token" du Dashboard.

---

## Étape 5 — Prometheus + Grafana (kube-prometheus-stack)

### Architecture complète du monitoring

```
┌──────────────────────────────────────────────────────────────────┐
│                    node-exporter (DaemonSet)                      │
│   un pod sur CHAQUE nœud → expose /metrics sur port 9100         │
│   métriques : CPU, RAM, disque, réseau du nœud                   │
└───────────────────────────┬──────────────────────────────────────┘
                            │ scrape HTTP toutes les 15s
                            ▼
┌──────────────────────────────────────────────────────────────────┐
│                    kube-state-metrics                             │
│   lit l'API K8s → expose des métriques sur les RESSOURCES K8s   │
│   ex: kube_pod_status_ready, kube_deployment_replicas_available  │
└───────────────────────────┬──────────────────────────────────────┘
                            │
                            ▼
┌──────────────────────────────────────────────────────────────────┐
│                       PROMETHEUS                                  │
│                                                                   │
│  Collecte (scrape) toutes les métriques toutes les 15 secondes   │
│  Stocke dans TSDB (base de données time-series sur disque)       │
│  Évalue des règles d'alerte (ex: CPU > 80% pendant 5 min)       │
│  Envoie les alertes à Alertmanager                               │
│                                                                   │
│  PromQL — langage de requête :                                    │
│    rate(http_requests_total[5m])     → requêtes/sec sur 5min     │
│    sum by (pod) (container_memory_usage_bytes)  → RAM par pod    │
└───────────────────────────┬──────────────────────────────────────┘
                            │ interroge via PromQL
                            ▼
┌──────────────────────────────────────────────────────────────────┐
│                        GRAFANA                                    │
│                                                                   │
│  Visualise les données Prometheus sous forme de dashboards       │
│  ~30 dashboards préconfigurés inclus dans le chart :             │
│    - Kubernetes / Compute Resources / Cluster                    │
│    - Kubernetes / Compute Resources / Node                       │
│    - Kubernetes / Compute Resources / Pod                        │
│    - Node Exporter / Full                                        │
│    - Alertmanager / Overview                                     │
└──────────────────────────────────────────────────────────────────┘
```

### `terraform/platform/monitoring.tf`

```hcl
resource "helm_release" "kube_prometheus_stack" {
  name       = "kube-prometheus-stack"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  namespace  = "monitoring"
  timeout    = 600   # 10 min — beaucoup d'images à télécharger

  set { name = "grafana.adminPassword",  value = "REDACTED_GRAFANA_PASSWORD" }

  # Stockage persistant pour Prometheus (utilise local-path)
  set { name = "prometheus.prometheusSpec.retention", value = "7d" }
  set { name = "prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.storageClassName",
        value = "local-path" }
  set { name = "prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.resources.requests.storage",
        value = "5Gi" }
}
```

```bash
terraform apply -auto-approve
# Durée : ~75 secondes
```

Vérification :
```bash
kubectl get pods -n monitoring
```
```
NAME                                                        READY   STATUS
alertmanager-kube-prometheus-stack-alertmanager-0           2/2     Running
kube-prometheus-stack-grafana-89dcf464-zkwvh                3/3     Running
kube-prometheus-stack-kube-state-metrics-54d6f58867-jtcnj   1/1     Running
kube-prometheus-stack-operator-54758db5fc-sp2c5             1/1     Running
kube-prometheus-stack-prometheus-node-exporter-p25fq        1/1     Running  ← node-1
kube-prometheus-stack-prometheus-node-exporter-r6m7v        1/1     Running  ← node-2
kube-prometheus-stack-prometheus-node-exporter-r8pdv        1/1     Running  ← node-3
kube-prometheus-stack-prometheus-node-exporter-wp7g2        1/1     Running  ← node-4
prometheus-kube-prometheus-stack-prometheus-0               2/2     Running
```

4 × `node-exporter` = un par nœud (DaemonSet).

### Accéder à Grafana

```bash
kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80 &
# → http://localhost:3000
# → admin / REDACTED_GRAFANA_PASSWORD
```

**Explorer les dashboards** :
- Menu gauche → Dashboards → Browse
- Chercher "Kubernetes / Compute Resources / Cluster" → vue CPU/RAM globale
- Chercher "Node Exporter Full" → métriques système des nœuds

---

## Étape 6 — Loki + Promtail (logs centralisés)

### Problème sans Loki

```bash
# Sans Loki, pour voir les logs d'un pod :
kubectl logs -n monitoring pod/kube-prometheus-stack-grafana-89dcf464-zkwvh

# Problèmes :
#  - Pod crashé ? logs PERDUS
#  - Chercher "ERROR" dans TOUS les pods ? impossible facilement
#  - Logs de la semaine dernière ? impossibles
```

### Solution : Loki + Promtail

```
Chaque nœud :
  Promtail (DaemonSet) lit /var/log/pods/
      → ajoute des labels {namespace, pod, container}
      → envoie en streaming à Loki

Loki :
      → stocke les logs compressés sur disque (local-path)
      → indexe uniquement les labels (pas le contenu → très efficace)
      → répond aux requêtes LogQL de Grafana
```

**Pourquoi Loki et pas Elasticsearch (ELK stack) ?**

```
ELK Stack (Elasticsearch + Logstash + Kibana)
  ✓ Très puissant, full-text search sur tout
  ✗ RAM : Elasticsearch nécessite 8-16GB de RAM
  ✗ Complexe à opérer en prod
  → adapté aux très grands volumes (milliards de logs/jour)

Loki
  ✓ N'indexe que les labels → très léger en RAM (256MB suffit)
  ✓ Même interface que Prometheus (Grafana)
  ✓ S3 comme backend en prod (pas cher)
  → parfait pour K8s
```

### `terraform/platform/logging.tf`

```hcl
resource "helm_release" "loki_stack" {
  name       = "loki-stack"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "loki-stack"
  namespace  = "logging"

  set { name = "promtail.enabled", value = "true"  }
  set { name = "grafana.enabled",  value = "false" }  # on a déjà Grafana
  set { name = "loki.persistence.enabled",           value = "true"       }
  set { name = "loki.persistence.storageClassName",  value = "local-path" }
  set { name = "loki.persistence.size",              value = "5Gi"        }
}
```

```bash
terraform apply -auto-approve
# Durée : ~90 secondes
```

Vérification :
```bash
kubectl get pods -n logging
```
```
NAME                        READY   STATUS
loki-stack-0                1/1     Running   ← Loki (1 instance)
loki-stack-promtail-6vwbp   1/1     Running   ← Promtail sur node-1
loki-stack-promtail-kmcvb   1/1     Running   ← Promtail sur node-2
loki-stack-promtail-w8q5j   1/1     Running   ← Promtail sur node-3
loki-stack-promtail-z5vpm   1/1     Running   ← Promtail sur node-4
```

### Connecter Loki à Grafana

Dans Grafana → Connections → Data sources → Add data source → Loki  
URL : `http://loki-stack.logging.svc.cluster.local:3100`

Puis → Explore → sélectionner Loki → requêtes LogQL :
```
# Tous les logs du namespace monitoring
{namespace="monitoring"}

# Seulement les erreurs
{namespace="monitoring"} |= "error"

# Logs du pod Prometheus
{pod=~"prometheus-.*"}
```

---

## État Terraform après tous les apply

```bash
terraform state list
```
```
helm_release.ingress_nginx
helm_release.kube_prometheus_stack
helm_release.loki_stack
kubernetes_cluster_role_binding.dashboard_admin
kubernetes_namespace.dashboard
kubernetes_namespace.ingress_nginx
kubernetes_namespace.logging
kubernetes_namespace.monitoring
kubernetes_namespace.ingress_nginx
null_resource.kubernetes_dashboard
null_resource.local_path_provisioner
kubernetes_service_account.dashboard_admin
```

**`terraform.tfstate`** : fichier JSON qui stocke l'état réel du déploiement.
C'est la "mémoire" de Terraform — il sait ce qui existe déjà vs ce qui est à créer.

⚠️ **Ne jamais supprimer ou modifier ce fichier manuellement.**  
**Ne jamais le committer** (il peut contenir des secrets).

En prod : stocker le state dans S3 + DynamoDB (verrouillage) :
```hcl
terraform {
  backend "s3" {
    bucket         = "mon-bucket-tfstate"
    key            = "kubequest/platform.tfstate"
    region         = "eu-central-1"
    dynamodb_table = "terraform-locks"
  }
}
```

---

## Résumé des accès

| Service | Commande port-forward | URL | Credentials |
|---|---|---|---|
| Grafana | `kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80` | http://localhost:3000 | admin / REDACTED_GRAFANA_PASSWORD |
| Prometheus | `kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090` | http://localhost:9090 | aucun |
| Alertmanager | `kubectl port-forward -n monitoring svc/kube-prometheus-stack-alertmanager 9093:9093` | http://localhost:9093 | aucun |
| Dashboard | `kubectl port-forward -n kubernetes-dashboard svc/kubernetes-dashboard 8443:443` | https://localhost:8443 | token (voir ci-dessous) |

```bash
# Générer un token Dashboard valide 24h
kubectl create token dashboard-admin -n kubernetes-dashboard --duration=24h
```

---

## En entreprise — différences clés

| Ce qu'on a fait | Ce qu'on ferait en prod | Raison |
|---|---|---|
| StorageClass `local-path` (disque local) | AWS EBS via ebs-csi-driver | Réplication, snapshots, backups automatiques |
| NodePort 30080/30443 | AWS ALB (LoadBalancer) + Route53 | IP publique fixe, TLS managé |
| Accès Grafana via port-forward | Ingress + cert-manager (TLS) | HTTPS public avec vrai certificat |
| Password admin en clair dans `.tf` | Kubernetes Secret + Vault | Rotation des secrets, audit trail |
| tfstate en local | tfstate dans S3 + DynamoDB lock | Travail en équipe, pas de conflits |
| Dashboard `cluster-admin` | RBAC granulaire + OIDC | Principe du moindre privilège |
| Loki sur disque local | Loki avec backend S3 | Durabilité, coût réduit, scalabilité |
| Prometheus 7 jours de rétention | Thanos ou Mimir (long-terme) | Analyse tendances sur 6-12 mois |

---

## Ce que tu as appris dans cette phase

- Ce qu'est un namespace et pourquoi on en utilise plusieurs
- Le flux complet `terraform plan` → `terraform apply` → vérification
- Pourquoi un StorageClass est nécessaire en kubeadm (vs EKS)
- Comment fonctionne un Ingress Controller (routage HTTP par domaine)
- L'architecture Prometheus : scrape → TSDB → PromQL → Grafana
- La différence entre métriques (Prometheus) et logs (Loki)
- Ce qu'est un DaemonSet (Promtail sur chaque nœud)
- Le rôle de `terraform.tfstate` et pourquoi ne pas le toucher manuellement
- Helm : gestionnaire de paquets K8s (`helm_release` dans Terraform = `helm install`)
