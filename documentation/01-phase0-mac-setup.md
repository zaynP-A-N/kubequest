# Phase 0 — Équiper le Mac (Poste de travail DevOps)

---

## Ce qu'on a fait

Installé tous les outils nécessaires pour piloter un cluster Kubernetes depuis un Mac.

### Outils installés

| Outil | Version | Rôle |
|---|---|---|
| **Homebrew** | 5.1.5 | Gestionnaire de paquets macOS |
| **AWS CLI** | 2.34.27 | Interagir avec AWS depuis le terminal |
| **kubectl** | v1.35.3 | Piloter le cluster Kubernetes |
| **Helm** | v4.1.4 | Déployer des applications K8s via charts |
| **k9s** | — | Interface TUI pour naviguer le cluster visuellement |
| **kubectx/kubens** | — | Switcher rapidement entre clusters/namespaces |
| **stern** | — | Voir les logs de plusieurs pods en temps réel |
| **Docker Desktop** | — | Builder et tester des images en local |

---

## Pourquoi on l'a fait

### Le principe fondamental : ton Mac ne fait QUE piloter

```
TON MAC                           SERVEURS AWS
──────────                        ────────────
kubectl ──── SSH tunnel ────────► K8s API server (node-1)
helm    ──── SSH tunnel ────────► K8s API server (node-1)
ssh     ────────────────────────► node-1, node-2, node-3, node-4

Rien ne s'installe sur ton Mac sauf les outils de pilotage.
Tout ce qui "tourne" (Kubernetes, apps, bases de données) est sur les VMs.
```

### Pourquoi Homebrew en premier ?

Homebrew est le gestionnaire de paquets standard sur macOS pour les développeurs. Il permet d'installer, mettre à jour et désinstaller des outils en une commande, avec gestion des dépendances. C'est l'équivalent de `apt` sur Ubuntu ou `dnf` sur Amazon Linux.

### Pourquoi kubectl sur le Mac ET sur les VMs ?

`kubectl` existe en deux modes :
- **Client** (sur ton Mac) → envoie des commandes à l'API K8s
- **Serveur** (installé silencieusement avec kubeadm sur les VMs) → reçoit et exécute

Ce sont deux binaires identiques — c'est le fichier `~/.kube/config` qui détermine à quel cluster il se connecte.

---

## En entreprise (production réelle)

### Poste de travail standard d'un Platform Engineer / DevOps

```
Outils supplémentaires :
  - terraform      → provisioning d'infrastructure (IaC)
  - aws-vault      → gestion sécurisée des credentials AWS (jamais en clair)
  - vault (HashiCorp) → gestion centralisée des secrets
  - lens ou k9s    → interface graphique cluster K8s
  - argocd CLI     → interagir avec le GitOps controller
  - pre-commit     → hooks Git pour valider le code avant commit
  - tflint/tfsec   → linting et scan sécurité Terraform
```

### Authentification AWS en entreprise

En entreprise, on n'utilise jamais de mot de passe ni de clé SSH stockée sur le poste. On utilise :
- **AWS IAM Identity Center (SSO)** → connexion via navigateur, token temporaire (1h)
- **aws-vault** → chiffre les credentials dans le keychain macOS
- **IAM Roles** → principe du moindre privilège, chaque outil a uniquement les droits dont il a besoin

### Exemple de workflow entreprise

```bash
# Connexion SSO (ouvre le navigateur, token 8h)
aws sso login --profile production

# Utiliser un rôle spécifique pour une action sensible
aws-vault exec production-admin -- terraform apply

# kubectl avec le bon contexte
kubectx production-cluster
kubectl get pods -n mon-app
```

---

## En lab (ce qu'on a fait ici et pourquoi)

### Simplifications acceptables en lab

| Ce qu'on a fait | Ce qu'on ferait en prod | Pourquoi c'est ok ici |
|---|---|---|
| Mot de passe console AWS | SSO + aws-vault | Compte école temporaire |
| Clé SSH stockée en clair `~/.ssh/` | Vault ou AWS Secrets Manager | Environnement non-critique |
| `insecure-skip-tls-verify` dans kubeconfig | Certificat TLS valide avec SAN | Impossible d'ouvrir le port 6443 (droits IAM école) |
| AWS CLI non configuré (pas d'access key) | Access key dans aws-vault | Droits IAM insuffisants pour créer une access key |

### La contrainte école expliquée

L'école utilise un compte AWS avec des **politiques IAM restrictives** :
- Pas de `iam:ListUsers` → impossible de voir les utilisateurs IAM
- Pas de `ec2:AuthorizeSecurityGroupIngress` → impossible de modifier les Security Groups
- Pas de `iam:CreateAccessKey` → impossible de créer des clés d'accès CLI

**Solution adoptée** : tunnel SSH sur le port 22 (déjà ouvert) pour faire passer le trafic kubectl.

---

## La commande d'installation expliquée

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

| Partie | Signification |
|---|---|
| `curl -fsSL` | Télécharge silencieusement (`-s`), suit les redirections (`-L`), échoue sur erreur HTTP (`-f`) |
| `raw.githubusercontent.com/...` | URL du script d'installation officiel Homebrew |
| `/bin/bash -c "..."` | Exécute le script téléchargé dans bash |

```bash
brew install awscli kubectl terraform helm k9s kubectx stern
brew install --cask docker
```

`--cask` = applications macOS avec interface graphique (Docker Desktop a une UI).
Sans `--cask` = outils en ligne de commande.

---

## Ce que tu as appris dans cette phase

- La différence entre un outil **client** (sur ton Mac) et un outil **serveur** (sur les VMs)
- Pourquoi séparer le poste de travail du serveur est une bonne pratique
- Le concept d'authentification par rôle IAM vs par clé
- Pourquoi les credentials ne doivent jamais être stockés en clair
