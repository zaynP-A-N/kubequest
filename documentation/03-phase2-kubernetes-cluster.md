# Phase 2 — Installation du cluster Kubernetes

---

## Ce qu'on a fait

1. Préparé les 4 nœuds (swap, kernel, containerd, kubeadm/kubelet/kubectl)
2. Initialisé le control-plane avec `kubeadm init` sur node-1
3. Installé Calico (plugin réseau CNI)
4. Rejoint node-2, node-3, node-4 au cluster avec `kubeadm join`
5. Configuré `kubectl` sur le Mac via tunnel SSH
6. Labellisé les nœuds

**Résultat** : cluster Kubernetes v1.29.15 avec 4 nœuds `Ready`.

---

## Architecture du cluster

```
┌──────────────────────────────────────────────────────────────┐
│                    CLUSTER KUBERNETES                         │
│                                                              │
│  ┌─────────────────────────────────────────────────────┐    │
│  │              node-1 (control-plane)                  │    │
│  │                                                      │    │
│  │  kube-apiserver    ← reçoit toutes les commandes     │    │
│  │  etcd              ← base de données du cluster      │    │
│  │  kube-scheduler    ← décide où placer les pods       │    │
│  │  controller-manager← maintient l'état désiré        │    │
│  │  kubelet           ← agent local                     │    │
│  │  calico-node       ← réseau des pods                 │    │
│  └─────────────────────────────────────────────────────┘    │
│                                                              │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐      │
│  │   node-2     │  │   node-3     │  │   node-4     │      │
│  │  (worker)    │  │  (worker)    │  │  (worker)    │      │
│  │              │  │              │  │              │      │
│  │  kubelet     │  │  kubelet     │  │  kubelet     │      │
│  │  kube-proxy  │  │  kube-proxy  │  │  kube-proxy  │      │
│  │  calico-node │  │  calico-node │  │  calico-node │      │
│  └──────────────┘  └──────────────┘  └──────────────┘      │
└──────────────────────────────────────────────────────────────┘
```

---

## Étape par étape — ce qui a été fait et pourquoi

### Étape 1 — Préparation des nœuds (`install-node.sh`)

#### 1a. Désactiver le swap

```bash
sudo swapoff -a
sudo sed -i '/swap/d' /etc/fstab
```

**Pourquoi ?** Le swap (espace disque utilisé comme RAM) pose un problème fondamental à Kubernetes : si un pod utilise du swap, ses performances deviennent imprévisibles. Kubernetes a besoin de savoir exactement quelle quantité de mémoire est disponible pour planifier les pods. Avec le swap, un nœud peut sembler "avoir de la mémoire" alors qu'il swap sur disque, ce qui est 1000x plus lent. Par défaut, `kubeadm` refuse de démarrer si le swap est actif.

`sed -i '/swap/d' /etc/fstab` → supprime la ligne swap du fichier de montage automatique, sinon le swap revient au redémarrage.

#### 1b. Modules kernel

```bash
sudo modprobe overlay
sudo modprobe br_netfilter
```

**`overlay`** : système de fichiers en couches utilisé par containerd pour les images Docker. Une image est constituée de couches en lecture seule + une couche en écriture. `overlay` rend ça possible.

**`br_netfilter`** : permet à iptables de voir et filtrer le trafic qui passe par les bridges réseau Linux. Sans ça, les NetworkPolicies Kubernetes ne fonctionneraient pas — le trafic entre pods passerait sans être inspecté.

```
/etc/modules-load.d/k8s.conf → charge ces modules automatiquement au démarrage
```

#### 1c. Paramètres sysctl

```bash
net.bridge.bridge-nf-call-iptables  = 1   # iptables voit le trafic bridge
net.bridge.bridge-nf-call-ip6tables = 1   # idem pour IPv6
net.ipv4.ip_forward                 = 1   # le nœud peut router des paquets
```

**`ip_forward`** : par défaut, Linux ne route pas les paquets entre ses interfaces réseau. Un ordinateur normal reçoit un paquet, si ce n'est pas pour lui il le jette. Avec `ip_forward=1`, il le transfère. C'est obligatoire pour que les pods sur node-2 puissent communiquer avec les pods sur node-3 via node-1.

#### 1d. containerd — le runtime de conteneurs

```bash
sudo dnf install -y containerd
containerd config default | sudo tee /etc/containerd/config.toml
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
```

**Pourquoi containerd et pas Docker ?**

```
Historique :
  2013 → Docker inventé (runtime + CLI + daemon + build + registry)
  2016 → Kubernetes utilise Docker comme runtime
  2020 → K8s annonce la dépréciation de Docker comme runtime
  2022 → K8s 1.24 retire dockershim (le bridge Docker→K8s)
  Aujourd'hui → containerd est le standard

Docker était trop "gros" pour K8s. K8s n'a besoin que de :
  - démarrer un conteneur
  - l'arrêter
  - observer son état
  
containerd fait exactement ça, sans UI ni CLI Docker.
Docker lui-même utilise containerd en dessous depuis 2017.
```

**`SystemdCgroup = true`** : Kubernetes et systemd doivent utiliser le même "cgroup driver". Si ce n'est pas le cas, il y a des conflits dans la gestion des ressources (CPU, RAM) des pods. `kubeadm` utilise systemd par défaut, donc containerd doit aussi l'utiliser.

#### 1e. kubeadm + kubelet + kubectl

```
kubeadm  → outil de bootstrap du cluster (utilisé une fois pour init/join)
kubelet  → agent qui tourne EN PERMANENCE sur chaque nœud
           il reçoit les ordres de l'API server et démarre/arrête les pods
kubectl  → CLI que TU utilises pour envoyer des commandes (client seulement)
```

---

### Étape 2 — `kubeadm init` (le moment fondateur)

```bash
sudo kubeadm init \
  --pod-network-cidr=192.168.0.0/16 \
  --apiserver-advertise-address=10.2.53.35 \
  --kubernetes-version=v1.29.15
```

**`--pod-network-cidr=192.168.0.0/16`** : le bloc d'adresses IP réservé aux pods. Calico (qu'on installera juste après) a besoin que ce soit `192.168.0.0/16`. Chaque pod reçoit une IP dans cette plage. Avec un /16 = 65 536 IPs disponibles pour les pods.

**`--apiserver-advertise-address=10.2.53.35`** : l'IP privée de node-1. C'est l'adresse que les workers utiliseront pour contacter l'API server. On utilise l'IP privée (pas publique) car les VMs communiquent entre elles via le réseau interne AWS (plus rapide, gratuit, sécurisé).

**Ce que kubeadm init a fait en 8 secondes** :

```
1. Vérifié les prérequis (swap désactivé, ports libres, etc.)
2. Téléchargé les images Docker des composants K8s
3. Généré les certificats TLS (CA, API server, etcd, kubelet...)
4. Créé les kubeconfigs (admin.conf, kubelet.conf, etc.)
5. Démarré etcd comme static pod
6. Démarré kube-apiserver comme static pod
7. Démarré kube-controller-manager comme static pod
8. Démarré kube-scheduler comme static pod
9. Configuré RBAC de base
10. Installé CoreDNS (DNS interne du cluster)
11. Installé kube-proxy (règles réseau sur chaque nœud)
12. Généré le token et la commande kubeadm join
```

**Static pods** = des pods démarrés directement par kubelet depuis des fichiers YAML dans `/etc/kubernetes/manifests/`, sans passer par l'API server. C'est nécessaire car l'API server lui-même doit démarrer quelque part.

---

### Étape 3 — Calico CNI (le réseau des pods)

```bash
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.27.3/manifests/calico.yaml
```

**Pourquoi un CNI est obligatoire ?**

Kubernetes crée un réseau virtuel pour les pods, mais il ne l'implémente pas lui-même. Il délègue ça à un plugin CNI (Container Network Interface). Sans CNI, les nœuds restent `NotReady` et les pods ne peuvent pas communiquer.

**Ce que Calico fait** :
- Assigne une IP unique à chaque pod (dans la plage `192.168.0.0/16`)
- Configure des routes sur chaque nœud pour que les pods puissent se joindre
- Implémente les **NetworkPolicies** (pare-feu entre pods) — Phase 6

**Pourquoi Calico et pas Flannel ou Cilium ?**

```
Flannel  → simple, pas de NetworkPolicy  → bien pour débuter, pas pour prod
Calico   → NetworkPolicy complètes, BGP routing → standard industrie
Cilium   → eBPF (plus performant), observabilité → tendance 2024-2026
Weave    → déprécié, ne plus utiliser
```

Calico est le choix de l'architecture du projet et c'est un choix solide — c'est l'un des CNI les plus utilisés en production.

---

### Étape 4 — `kubeadm join` (les workers rejoignent)

```bash
sudo kubeadm join 10.2.53.35:6443 \
  --token qqsjom.fzzdgzr4d2z7ysxu \
  --discovery-token-ca-cert-hash sha256:d7900168e...
```

**Le token** : généré par `kubeadm init`, valide 24h. Il sert à authentifier les workers qui veulent rejoindre. Sans lui, n'importe qui pourrait ajouter un nœud malveillant au cluster.

**Le hash CA** : empreinte cryptographique du certificat CA du cluster. Le worker l'utilise pour vérifier qu'il parle bien au bon control-plane (pas à un imposteur). C'est la protection contre les attaques man-in-the-middle.

**Processus de join** :
```
worker ──(token)──► API server node-1
API server vérifie le token + hash CA
Crée un certificat pour le kubelet du worker
Worker est maintenant membre du cluster
```

---

### Étape 5 — kubeconfig sur le Mac (tunnel SSH)

**Problème rencontré** : le port 6443 (API K8s) est bloqué par le Security Group AWS car l'école n'a pas donné les droits `ec2:AuthorizeSecurityGroupIngress`.

**Solution : tunnel SSH**

```bash
ssh -L 6443:10.2.53.35:6443 node-1 -N -f
```

| Option | Signification |
|---|---|
| `-L 6443:10.2.53.35:6443` | Écoute sur localhost:6443, redirige vers 10.2.53.35:6443 |
| `-N` | Ne pas exécuter de commande (juste le tunnel) |
| `-f` | Passe en arrière-plan |

```
ton Mac:6443 ──(SSH chiffré port 22)──► node-1 ──► node-1:6443 (API server)
```

Le trafic kubectl est chiffré deux fois : TLS K8s + SSH.

**`insecure-skip-tls-verify: true`** dans le kubeconfig : le certificat TLS de l'API server est signé pour `10.2.53.35`, pas pour `127.0.0.1`. On désactive la vérification du nom (acceptable en lab, jamais en prod).

---

## Vérification finale

```bash
kubectl get nodes
```

```
NAME                                           STATUS   ROLES                  AGE   VERSION
ip-10-2-53-35.eu-central-1.compute.internal    Ready    control-plane,worker   22m   v1.29.15
ip-10-2-53-34.eu-central-1.compute.internal    Ready    worker                 20m   v1.29.15
ip-10-2-53-69.eu-central-1.compute.internal    Ready    worker                 20m   v1.29.15
ip-10-2-53-145.eu-central-1.compute.internal   Ready    worker                 20m   v1.29.15
```

```bash
kubectl get pods -n kube-system
```

Les pods système qui doivent être `Running` :

| Pod | Rôle |
|---|---|
| `kube-apiserver` | Reçoit toutes les commandes kubectl |
| `etcd` | Base de données clé-valeur du cluster (état désiré) |
| `kube-controller-manager` | Boucles de contrôle (ReplicaSet, Deployment...) |
| `kube-scheduler` | Décide sur quel nœud placer chaque pod |
| `coredns` | DNS interne (résolution `mon-service.mon-namespace.svc.cluster.local`) |
| `kube-proxy` | Règles iptables pour le trafic vers les Services |
| `calico-node` | Agent Calico sur chaque nœud |
| `calico-kube-controllers` | Synchronise Calico avec l'état K8s |

---

## En entreprise (production réelle)

### Installation K8s en prod — les vraies options

```
Option 1 : Managed Kubernetes (recommandé)
  AWS EKS    → Amazon Elastic Kubernetes Service
  GKE        → Google Kubernetes Engine
  AKS        → Azure Kubernetes Service

  Avantages : control-plane géré par le cloud provider
               patches de sécurité automatiques
               intégration native avec les services cloud (IAM, LB, storage)
  
  L'ingénieur n'installe pas kubeadm — il crée le cluster via Terraform :
  
  resource "aws_eks_cluster" "main" {
    name     = "production"
    role_arn = aws_iam_role.eks.arn
    version  = "1.29"
  }

Option 2 : kubeadm (comme on a fait)
  Utilisé pour : clusters on-premise, datacenters privés, lab
  Contrôle total mais responsabilité totale (patches, HA, backup etcd)

Option 3 : k3s
  Version allégée de K8s par Rancher
  Utilisé pour : edge computing, IoT, environnements avec peu de RAM
  Un seul binaire < 100MB
```

### Haute disponibilité en prod

En production, le control-plane est **en haute disponibilité** (HA) :

```
3 nœuds control-plane (toujours un nombre impair pour le quorum etcd)
  ┌──────────────┐   ┌──────────────┐   ┌──────────────┐
  │  master-1    │   │  master-2    │   │  master-3    │
  │  etcd leader │◄──┤  etcd follower│◄──┤  etcd follower│
  │  API server  │   │  API server  │   │  API server  │
  └──────┬───────┘   └──────┬───────┘   └──────┬───────┘
         └──────────────────┴──────────────────┘
                             │
                    Load Balancer (AWS ALB)
                             │
                    kubectl depuis le Mac
```

Si master-1 tombe, master-2 ou master-3 prennent le relais. Pas d'interruption de service.

### Calico en prod

En prod, Calico est souvent configuré avec **BGP** (Border Gateway Protocol) pour annoncer les routes des pods aux routeurs du datacenter — ça permet une intégration réseau plus poussée.

---

## En lab (ce qu'on a fait ici et pourquoi)

| Ce qu'on a fait | Ce qu'on ferait en prod | Raison |
|---|---|---|
| 1 seul control-plane | 3 control-planes en HA | Pas assez de machines |
| kubeadm manuel | Terraform + EKS | Apprendre les fondamentaux |
| Tunnel SSH pour kubectl | Port 6443 ouvert avec restriction IP | Droits IAM école insuffisants |
| `insecure-skip-tls-verify` | Certificat avec le bon SAN | Conséquence du tunnel SSH |
| control-plane aussi worker | control-plane dédié (taint NoSchedule) | Pas assez de nœuds pour séparer |
| Token kubeadm hardcodé | Token regénéré via automation | Lab, pas de rotation nécessaire |

### Note sur le taint control-plane

Par défaut, kubeadm met un **taint** sur le control-plane :
```
node-role.kubernetes.io/control-plane:NoSchedule
```

Ça empêche les pods "utilisateur" de tourner sur le control-plane (pour ne pas interférer avec les composants K8s). On a gardé ce taint (node-1 est donc à la fois control-plane ET worker grâce au label qu'on a ajouté — certains pods système peuvent y tourner).

---

## Commandes utiles à retenir

```bash
# État du cluster
kubectl get nodes
kubectl get nodes -o wide          # avec IPs et OS
kubectl describe node <nom>        # détails complets d'un nœud

# Pods système
kubectl get pods -n kube-system
kubectl get pods -n kube-system -o wide   # avec le nœud où ils tournent

# Logs d'un composant
kubectl logs -n kube-system kube-apiserver-<...>

# Tunnel kubectl (à lancer au début de chaque session)
bash kubernetes/scripts/tunnel.sh

# Vérifier si le tunnel est actif
bash kubernetes/scripts/tunnel.sh status
```

---

## Ce que tu as appris dans cette phase

- Les composants internes de Kubernetes (API server, etcd, scheduler, etc.)
- Pourquoi le swap doit être désactivé
- Le rôle de chaque module kernel (`overlay`, `br_netfilter`)
- La différence entre containerd et Docker
- Ce que fait `kubeadm init` en détail
- Comment fonctionne le CNI et pourquoi Calico
- Le mécanisme du `kubeadm join` (token + hash CA)
- Les tunnels SSH et le port forwarding
- La différence entre un cluster HA et un cluster lab à 1 control-plane
