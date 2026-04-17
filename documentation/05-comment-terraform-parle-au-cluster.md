# Comment Terraform parle à ton cluster Kubernetes

---

## La question

Quand tu tapes `terraform apply` depuis ton Mac, Terraform déploie
des ressources dans un cluster qui tourne sur des VMs en Allemagne (AWS
eu-central-1). Comment est-ce possible ? Qui parle à qui ?

---

## La chaîne complète

```
ton Mac
  │
  │  terraform apply
  │
  ▼
┌─────────────────────────────────────────────────────┐
│               Terraform (binaire local)              │
│                                                      │
│  Lit les fichiers .tf                               │
│  Charge les providers (binaires dans .terraform/)   │
│  Compare tfstate actuel vs état désiré              │
└────────────────────┬────────────────────────────────┘
                     │
         ┌───────────┴────────────┐
         │                        │
         ▼                        ▼
┌─────────────────┐    ┌──────────────────────┐
│ provider        │    │ provider             │
│ "kubernetes"    │    │ "helm"               │
│ (hashicorp)     │    │ (hashicorp)          │
│                 │    │                      │
│ Lit            │    │ Même chose —         │
│ ~/.kube/config  │    │ utilise kubectl      │
│                 │    │ en dessous           │
└────────┬────────┘    └──────────┬───────────┘
         │                        │
         └───────────┬────────────┘
                     │
                     │  appels HTTPS vers https://127.0.0.1:6443
                     ▼
┌─────────────────────────────────────────────────────┐
│               TUNNEL SSH (actif en arrière-plan)     │
│                                                      │
│  localhost:6443  ──────►  node-1:6443               │
│                                                      │
│  (ouvert par : ssh -L 6443:10.2.53.35:6443 node-1)  │
└────────────────────┬────────────────────────────────┘
                     │
                     │  trafic chiffré SSH sur port 22
                     ▼
┌─────────────────────────────────────────────────────┐
│               node-1 (EC2, IP 3.74.128.83)           │
│                                                      │
│  kube-apiserver                                      │
│  écoute sur 10.2.53.35:6443                         │
│                                                      │
│  Vérifie les credentials → exécute l'action         │
│  Écrit dans etcd                                    │
│  kubelet sur les workers reçoit les ordres          │
└─────────────────────────────────────────────────────┘
```

---

## Étape par étape — ce qui se passe pendant un `terraform apply`

### 1. Terraform lit `~/.kube/config`

```yaml
# ~/.kube/config (simplifié)
clusters:
  - name: kubernetes
    cluster:
      server: https://127.0.0.1:6443        ← adresse du "serveur"
      insecure-skip-tls-verify: true

users:
  - name: kubernetes-admin
    user:
      client-certificate-data: <base64>     ← certificat TLS du client
      client-key-data: <base64>             ← clé privée du client

contexts:
  - name: kubernetes-admin@kubernetes
    context:
      cluster: kubernetes
      user: kubernetes-admin
```

C'est le même fichier que kubectl utilise. Terraform le lit via :
```hcl
provider "kubernetes" {
  config_path    = "~/.kube/config"
  config_context = "kubernetes-admin@kubernetes"
}
```

### 2. Le provider crée un client HTTP

Le provider `hashicorp/kubernetes` (binaire téléchargé dans `.terraform/`) crée
un **client HTTP Go** configuré avec :
- URL : `https://127.0.0.1:6443`
- Certificat client TLS (pour s'authentifier)
- `InsecureSkipVerify: true` (car le certificat du serveur est au nom de `10.2.53.35`, pas `127.0.0.1`)

### 3. Les requêtes passent dans le tunnel SSH

```
Terraform provider
    │
    │  HTTP POST https://127.0.0.1:6443/api/v1/namespaces
    │  Body: {"metadata": {"name": "monitoring"}}
    ▼
Port 6443 sur localhost
    │
    │  Le tunnel SSH intercepte ce trafic
    │  (créé par : ssh -L 6443:10.2.53.35:6443 node-1 -N -f)
    │
    │  127.0.0.1:6443  →  node-1  →  10.2.53.35:6443
    ▼
kube-apiserver sur node-1
```

Le tunnel SSH est **transparent** : ni Terraform ni le provider ne savent
qu'il existe. Ils pensent parler à un serveur local sur `127.0.0.1`.

### 4. L'API server authentifie la requête

L'API server K8s reçoit la requête avec le **certificat client TLS** inclus.

```
Certificat client contient :
  Subject: O=system:masters, CN=kubernetes-admin

L'API server voit : "O=system:masters" → le groupe system:masters
                                        → autorisé à TOUT faire (cluster-admin)
```

C'est de l'**authentification mutuelle TLS (mTLS)** :
- Le client (Terraform) présente son certificat
- Le serveur (API server) vérifie que ce certificat est signé par sa CA
- Pas de mot de passe — uniquement des certificats cryptographiques

### 5. L'API server écrit dans etcd

```
API server reçoit : "créer namespace monitoring"
      │
      ▼
Valide (certificats OK, droits OK)
      │
      ▼
Écrit dans etcd :
  /registry/namespaces/monitoring → {metadata: {name: "monitoring", ...}}
      │
      ▼
Répond 201 Created → Terraform reçoit la confirmation
      │
      ▼
Terraform met à jour terraform.tfstate
```

### 6. Pour Helm — même chose + logique supplémentaire

Le provider `helm` fait tout ça, plus :
1. Télécharge le chart depuis le repo Helm (internet → ton Mac)
2. Génère les manifests YAML depuis le chart + les `set {}` du .tf
3. Envoie chaque manifest à l'API server via HTTPS
4. Stocke la release Helm dans un Secret K8s dans le namespace cible

```bash
# Tu peux voir les releases Helm directement dans K8s :
kubectl get secrets -n monitoring | grep helm
# → sh.helm.release.v1.kube-prometheus-stack.v1   helm.sh/release.v1
```

---

## Récapitulatif visuel de l'authentification

```
terraform apply
      │
      │  lit ~/.kube/config
      ▼
provider kubernetes/helm
      │
      │  TLS mutuel (certificats)
      │  + tunnel SSH transparent
      ▼
kube-apiserver
      │
      │  "kubernetes-admin = system:masters = cluster-admin"
      ▼
etcd (base de données du cluster)
      │
      ▼
kubelet sur les workers (pour démarrer les pods)
```

---

## Pourquoi le tunnel SSH doit être actif avant `terraform apply`

Sans tunnel :
```
Terraform → https://127.0.0.1:6443
                        │
                        ▼
              Connection refused ← rien n'écoute sur ce port
              
terraform apply échoue avec :
  "dial tcp 127.0.0.1:6443: connect: connection refused"
```

Avec tunnel :
```
Terraform → https://127.0.0.1:6443
                        │
                  tunnel SSH
                        │
                        ▼
              kube-apiserver sur node-1 → répond 200 OK
```

**Règle absolue** : toujours vérifier que le tunnel est actif avant
`terraform apply` ou `kubectl` :

```bash
bash kubernetes/scripts/tunnel.sh status   # vérifier
bash kubernetes/scripts/tunnel.sh start    # démarrer si nécessaire
```

---

## En entreprise — comment ça se passe sans tunnel SSH

En prod sur EKS, il n'y a pas de tunnel SSH. L'authentification se fait
différemment :

```
Option 1 : kubeconfig avec credentials IAM AWS
──────────────────────────────────────────────
# ~/.kube/config en prod EKS :
  server: https://XXXX.gr7.eu-central-1.eks.amazonaws.com
  # (domaine public EKS, accessible depuis internet)

  exec:
    command: aws
    args: ["eks", "get-token", "--cluster-name", "production"]
    # AWS CLI génère un token temporaire valide 15 min
    # basé sur l'identité IAM de la machine

→ Terraform sur le Mac se connecte directement au domaine EKS
→ Authentification = token AWS IAM (pas de certificat client)
→ Pas besoin de tunnel


Option 2 : Terraform dans une CI/CD (GitLab CI, GitHub Actions)
────────────────────────────────────────────────────────────────
# Le pipeline tourne dans AWS (même VPC que le cluster)
# → accès direct à l'API server sans tunnel

# .gitlab-ci.yml :
terraform:apply:
  script:
    - terraform apply -auto-approve
  environment:
    AWS_ROLE_ARN: arn:aws:iam::649966626926:role/terraform-deployer

→ Le runner GitLab assume un rôle IAM
→ Génère un token EKS → accès à l'API server
→ Tout se passe dans le réseau AWS (pas d'internet nécessaire)
```

---

## Ce que tu as appris

- `~/.kube/config` est la clé de tout — il contient les credentials et l'adresse du cluster
- Le tunnel SSH rend `127.0.0.1:6443` accessible même si le port 6443 est bloqué sur AWS
- L'authentification K8s se fait par **mTLS** (certificats, pas mots de passe)
- Le provider Terraform n'est qu'un client HTTP Go qui appelle l'API K8s
- Helm stocke ses releases dans des Secrets K8s (pas sur ton Mac)
- En prod EKS : kubeconfig + token IAM AWS, pas besoin de tunnel
