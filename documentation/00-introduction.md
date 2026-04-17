# KubeQuest – Documentation d'apprentissage
## Group-53 | Epitech MSc 2026

---

## À propos de ce dossier

Ce dossier contient l'explication complète de chaque phase du projet.
Pour chaque phase tu trouveras :

- **Ce qu'on a fait** — les actions concrètes
- **Pourquoi on l'a fait** — le raisonnement technique
- **En entreprise** — comment ça se passe en production réelle
- **En lab (ici)** — les simplifications qu'on a faites et pourquoi
- **Les commandes clés** — avec leur explication ligne par ligne

---

## Vue d'ensemble du projet

```
┌─────────────────────────────────────────────────────────┐
│                    TON MAC (cockpit)                     │
│   kubectl ──────────────────────────────────────────►   │
│   helm    ──── SSH tunnel ──► API K8s (port 6443)   ►   │
│   ssh     ──────────────────────────────────────────►   │
└─────────────────────────────────────────────────────────┘
                          │
              ┌───────────▼─────────────────┐
              │     AWS EC2 eu-central-1     │
              │                              │
              │  node-1 (control-plane)      │
              │    IP fixe: 3.74.128.83      │
              │    IP privée: 10.2.53.35     │
              │                              │
              │  node-2 (worker)             │
              │    IP privée: 10.2.53.34     │
              │                              │
              │  node-3 (worker)             │
              │    IP privée: 10.2.53.69     │
              │                              │
              │  node-4 (worker)             │
              │    IP privée: 10.2.53.145    │
              └──────────────────────────────┘
```

---

## Ordre des phases

| Phase | Contenu | Statut |
|---|---|---|
| Phase 0 | Équiper le Mac (outils DevOps) | ✅ Fait |
| Phase 1 | Accès AWS + clé SSH | ✅ Fait |
| Phase 2 | Installation du cluster Kubernetes | ✅ Fait |
| Phase 3 | Services de plateforme (ingress, monitoring, logs) | ⏳ À faire |
| Phase 4 | Migration de l'app docker-compose vers K8s | ⏳ À faire |
| Phase 5 | Helm charts + GitOps (Kustomize) | ⏳ À faire |
| Phase 6 | Sécurité (RBAC, NetworkPolicy, OPA) | ⏳ À faire |

---

## Infrastructure résumée

| Machine | OS | Rôle K8s | IP publique | IP privée |
|---|---|---|---|---|
| ec2-group-53-node-1 | Amazon Linux 2023 ARM64 | control-plane + worker | 3.74.128.83 (Elastic IP fixe) | 10.2.53.35 |
| ec2-group-53-node-2 | Amazon Linux 2023 ARM64 | worker | dynamique | 10.2.53.34 |
| ec2-group-53-node-3 | Amazon Linux 2023 ARM64 | worker | dynamique | 10.2.53.69 |
| ec2-group-53-node-4 | Amazon Linux 2023 ARM64 | worker | dynamique | 10.2.53.145 |

**Type d'instance** : t4g.medium (2 vCPU, 4 GiB RAM, architecture ARM64/Graviton)

---

## Lexique rapide

| Terme | Définition simple |
|---|---|
| **Pod** | La plus petite unité K8s — 1 ou plusieurs conteneurs qui tournent ensemble |
| **Node** | Une machine (VM) qui fait partie du cluster |
| **Control-plane** | Le "cerveau" du cluster — planifie et surveille tout |
| **Worker** | Un nœud qui exécute les pods (les applications) |
| **kubectl** | La CLI pour envoyer des commandes au cluster |
| **Helm** | Le gestionnaire de paquets pour K8s (comme apt/brew mais pour K8s) |
| **Namespace** | Espace de noms pour isoler des ressources dans le cluster |
| **Ingress** | Règle qui dit "ce domaine/chemin va vers ce service" |
| **CNI** | Plugin réseau — permet aux pods de se parler entre eux |
