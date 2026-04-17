# Sealed Secrets — Chiffrement des credentials pour GitOps

## Pourquoi on a besoin de Sealed Secrets

### Le problème fondamental de GitOps + Secrets

GitOps repose sur un principe simple : **tout ce qui tourne dans le cluster doit être décrit dans Git**. ArgoCD surveille le repo et synchronise automatiquement l'état du cluster avec le contenu du repo.

Mais un Secret Kubernetes est encodé en base64, **pas chiffré** :

```yaml
# Ce que tu commites dans Git
apiVersion: v1
kind: Secret
metadata:
  name: mysql-secret
data:
  mysql-password: <base64-de-votre-password>   # ← base64 simple
```

```bash
# N'importe qui peut décoder ça en 1 seconde
echo "<base64-de-votre-password>" | base64 --decode
# → REDACTED_DB_PASSWORD
```

**Le paradoxe GitOps** : si tu peux tout commiter sauf les secrets, tu n'as pas vraiment un état complet dans Git. Si le cluster est détruit, tu peux tout reconstruire depuis Git… sauf les secrets.

Sealed Secrets résout ce paradoxe : **les secrets chiffrés sont safe à commiter dans Git**.

---

## Le principe de Sealed Secrets

Sealed Secrets utilise le **chiffrement asymétrique** (aussi appelé chiffrement à clé publique/privée — le même principe que SSL/TLS ou SSH).

### La cryptographie asymétrique en 2 minutes

```
Clé PUBLIQUE  → chiffre les données   (tout le monde peut l'avoir)
Clé PRIVÉE    → déchiffre les données (jamais partagée, jamais quittée le cluster)
```

**Analogie** : la clé publique est comme un cadenas ouvert que tu distribues librement. N'importe qui peut mettre un message dans une boîte et la fermer avec ton cadenas. Mais seul toi — avec ta clé privée — peux ouvrir la boîte.

Dans Sealed Secrets :
- La **clé privée** est générée automatiquement et stockée dans un Secret K8s dans `kube-system`. Elle ne quitte jamais le cluster.
- La **clé publique** est distribuable librement — elle ne permet que de chiffrer, pas de déchiffrer.

---

## Architecture des composants

```
┌─────────────────────────────────────────────────────────────────┐
│  TON MAC                                                        │
│                                                                 │
│  kubeseal CLI ──────── clé publique (cert.pem) ─────────────►  │
│       │                                                         │
│  valeurs en clair ──► chiffrement ──► SealedSecret.yaml (safe) │
│                                              │                  │
└──────────────────────────────────────────────┼──────────────────┘
                                               │ git push
                                               ▼
                                          GitLab (repo)
                                               │
                                               │ ArgoCD sync
                                               ▼
┌─────────────────────────────────────────────────────────────────┐
│  CLUSTER KUBERNETES                                             │
│                                                                 │
│  sealed-secrets-controller (kube-system)                       │
│       │                                                         │
│       ├── possède la clé PRIVÉE                                 │
│       ├── détecte les nouvelles ressources SealedSecret         │
│       ├── déchiffre avec la clé privée                          │
│       └── crée le vrai K8s Secret dans le namespace cible       │
│                        │                                        │
│                        ▼                                        │
│           Secret mysql-secret (namespace: app)                  │
│           mysql-password: REDACTED_DB_PASSWORD   ← en clair en RAM      │
│                        │                                        │
│             MySQL Pod, Laravel Pod                              │
└─────────────────────────────────────────────────────────────────┘
```

---

## Les ressources Kubernetes impliquées

### 1. Le Controller — `sealed-secrets-controller`

C'est un **Deployment** installé dans `kube-system`. C'est le cerveau du système.

```bash
kubectl get deployment sealed-secrets-controller -n kube-system
# NAME                        READY   UP-TO-DATE
# sealed-secrets-controller   1/1     1
```

À son démarrage, il :
1. Génère une paire de clés RSA-4096 (ou vérifie qu'elle existe déjà)
2. Stocke la clé privée dans un Secret K8s dans `kube-system` (accessible seulement aux admins cluster)
3. Expose la clé publique via son API (accessible à `kubeseal`)
4. Se met en veille et surveille les nouvelles ressources `SealedSecret`

Quand un `SealedSecret` est créé dans le cluster :
1. Le controller le détecte via le mécanisme de `watch` de K8s
2. Lit le payload chiffré
3. Déchiffre avec la clé privée RSA
4. Crée un `Secret` K8s standard dans le même namespace

### 2. La Custom Resource `SealedSecret`

C'est la ressource K8s que tu commites dans Git. Elle ressemble à un Secret mais le contenu est chiffré :

```yaml
apiVersion: bitnami.com/v1alpha1   # ← API custom, pas la native K8s
kind: SealedSecret                  # ← nouveau type créé par le controller
metadata:
  name: mysql-secret
  namespace: app
spec:
  encryptedData:
    mysql-password: AgBy8hRioLsQlsi4RxoG...  # ← chiffré RSA-AES, illisible
    mysql-root-password: Ag3Bx9pKmN7vTq...   # ← chiffré indépendamment
    mysql-database: AgBkzL9pxK...
    mysql-user: AgCdM7nKp...
  template:
    metadata:
      name: mysql-secret             # le Secret K8s qui sera créé
      namespace: app
```

**Caractéristiques importantes :**
- Chaque clé (`mysql-password`, `mysql-root-password`...) est chiffrée **indépendamment**
- La chaîne chiffrée contient aussi le nom et le namespace comme contexte — un SealedSecret chiffré pour le namespace `app` ne peut pas être réutilisé dans le namespace `prod` (protection contre la copie entre environnements)
- Si tu changes une valeur, seule cette clé change dans le fichier → diff Git lisible

### 3. `kubeseal` — le CLI sur ton Mac

C'est l'outil qui chiffre. Il prend un Secret K8s standard en entrée et produit un SealedSecret chiffré en sortie.

```bash
# Principe général
kubectl create secret generic mysql-secret \
  --from-literal=mysql-password="REDACTED_DB_PASSWORD" \
  --dry-run=client -o yaml \          # ← crée le Secret en mémoire, sans l'envoyer au cluster
  | kubeseal \
    --cert cert.pem \                  # ← clé publique du controller
    --format yaml \                    # ← output en YAML (alternatif: json)
  > sealed-mysql-secret.yaml           # ← fichier safe à commiter
```

**`--dry-run=client -o yaml`** : génère le manifest YAML du Secret sans l'appliquer au cluster. Ce YAML est passé via le pipe `|` à `kubeseal` qui le chiffre.

---

## Le chiffrement en détail

Sealed Secrets utilise un **chiffrement hybride** : RSA pour la clé, AES pour les données. C'est le même principe que TLS.

```
1. kubeseal génère une clé AES-256 aléatoire (pour ce secret spécifique)
2. kubeseal chiffre les données avec AES-256-GCM
   → données chiffrées (même si longues, AES est rapide)
3. kubeseal chiffre la clé AES avec la clé publique RSA du controller
   → clé chiffrée (petite, RSA est lent mais OK pour les petites données)
4. Le SealedSecret = clé AES chiffrée + données chiffrées

Pour déchiffrer (le controller):
1. Déchiffre la clé AES avec la clé privée RSA
2. Déchiffre les données avec la clé AES
```

**Pourquoi ce chiffrement hybride ?**
RSA ne peut chiffrer que des données courtes (< 256 bytes pour RSA-2048). Un mot de passe, ça passe, mais un certificat TLS ou une config longue — non. AES est symétrique et peut chiffrer n'importe quelle taille.

---

## Portée du chiffrement (scope)

Sealed Secrets offre 3 niveaux de "scope" qui déterminent où un SealedSecret peut être décrypté :

| Scope | Signification | Usage |
|---|---|---|
| `strict` (défaut) | Lié au **nom ET namespace** | Production — le plus sécurisé |
| `namespace-wide` | Lié au **namespace** uniquement | Le nom peut changer |
| `cluster-wide` | Lié à aucun namespace | Secrets partagés entre namespaces |

Avec le scope `strict` (notre cas) :
- Un SealedSecret nommé `mysql-secret` dans le namespace `app` ne peut être déchiffré **que** dans `app` par le controller
- Si tu copies le fichier et changes le namespace en `staging` → le controller refuse de déchiffrer → protection contre la réutilisation entre environnements

---

## Rotation des clés du controller

La clé privée RSA du controller est le composant le plus critique. Sealed Secrets gère une rotation automatique :

```
J+0    : clé RSA-1 générée (active)
J+30   : clé RSA-2 générée (active), RSA-1 toujours valide pour déchiffrer les anciens SealedSecrets
J+60   : clé RSA-3 générée (active), RSA-1 et RSA-2 toujours valides
...
```

Par défaut la rotation est tous les **30 jours**. Les anciennes clés sont conservées (pour déchiffrer les anciens SealedSecrets) mais ne sont plus utilisées pour chiffrer de nouveaux secrets.

```bash
# Voir toutes les clés disponibles
kubectl get secrets -n kube-system -l sealedsecrets.bitnami.com/sealed-secrets-key
```

**Important** : si tu perds la clé privée (suppression accidentelle du namespace `kube-system`), tes SealedSecrets deviennent **indéchiffrables pour toujours**. La seule solution est de tout rechiffrer avec une nouvelle clé publique.

```bash
# Sauvegarder la clé privée (à stocker en lieu sûr, PAS dans Git)
kubectl get secret -n kube-system \
  -l sealedsecrets.bitnami.com/sealed-secrets-key \
  -o yaml > sealed-secrets-master-key-BACKUP.yaml
# → stocker dans un gestionnaire de mots de passe ou AWS Secrets Manager
```

---

## Workflow complet — du développement au déploiement

```
                    TON MAC                    GITLAB           CLUSTER K8s

[1] Créer values-secrets.yaml (gitignored)
    password: mon_vrai_mot_de_passe

[2] Lancer setup-sealed-secrets.sh
    → récupère cert.pem (clé publique)
    → chiffre chaque credential
    → génère sealed-mysql-secret.yaml ────────► [3] git push ──► [4] ArgoCD détecte

                                                                  [5] Applique
                                                                  SealedSecret
                                                                        │
                                                                  [6] Controller
                                                                  déchiffre
                                                                        │
                                                                  [7] Crée Secret
                                                                  mysql-secret
                                                                        │
                                                                  [8] MySQL + Laravel
                                                                  lisent les credentials
```

---

## Ce que voit quelqu'un qui clone le repo

```bash
git clone https://gitlab.com/fotsodjeff/t-clo-902_msc2026.git
cat kubernetes/sealed-secrets/sealed-mysql-secret.yaml
```

```yaml
spec:
  encryptedData:
    mysql-password: AgBy8hRioLsQlsi4RxoGW3VoBQWLrAQXfgQH...
    # ↑ 500+ caractères de données RSA+AES chiffrées
    # Sans la clé privée du cluster → inutilisable
```

**Que peut faire un attaquant avec ça ?**
- Lire le fichier ? Oui → voit du bruit chiffré, aucune information utile
- Déchiffrer ? Non → nécessite la clé RSA privée stockée dans `kube-system`
- Réutiliser dans un autre cluster ? Non → le chiffrement inclut le namespace comme contexte, un autre cluster a une clé différente
- Bruteforcer ? AES-256 + RSA-4096 → infaisable même avec des supercalculateurs

---

## Comparaison avec les alternatives

| Solution | Safe to commit | Complexité | Nécessite service externe | GitOps compatible |
|---|---|---|---|---|
| **Secret K8s brut** | ❌ base64 ≠ chiffrement | Faible | Non | Non |
| **Sealed Secrets** | ✅ | Faible | Non (controller in-cluster) | ✅ |
| **SOPS + age** | ✅ | Moyenne | Non (clé age sur le Mac) | ✅ |
| **SOPS + AWS KMS** | ✅ | Moyenne | ✅ AWS KMS | ✅ |
| **External Secrets + Vault** | ✅ | Élevée | ✅ HashiCorp Vault | ✅ |
| **External Secrets + AWS SM** | ✅ | Élevée | ✅ AWS Secrets Manager | ✅ |

**Pourquoi Sealed Secrets pour notre projet :**
- Pas besoin d'un service externe (Vault, AWS KMS)
- Très simple à installer (1 helm install)
- Nativement compatble ArgoCD/GitOps
- Standard dans les projets K8s mid-size

**En grande entreprise** → External Secrets Operator + HashiCorp Vault : les secrets ne sont jamais dans Git même chiffrés, ils sont tirés dynamiquement depuis Vault au démarrage du pod. Le cluster n'a accès qu'à Vault avec un token JWT limité.

---

## Commandes de référence

```bash
# ── INSTALLATION ──────────────────────────────────────────────────

# Installer le controller dans le cluster
helm install sealed-secrets sealed-secrets/sealed-secrets \
  --namespace kube-system \
  --set fullnameOverride=sealed-secrets-controller

# Installer kubeseal CLI (Mac ARM64)
brew install kubeseal

# ── UTILISATION ───────────────────────────────────────────────────

# Récupérer la clé publique du controller
kubeseal --fetch-cert \
  --controller-name=sealed-secrets-controller \
  --controller-namespace=kube-system \
  > cert.pem

# Chiffrer un Secret existant
kubectl create secret generic mon-secret \
  --from-literal=password="mon_mot_de_passe" \
  --dry-run=client -o yaml \
  | kubeseal --cert cert.pem --format yaml > sealed-mon-secret.yaml

# Chiffrer depuis un fichier .env
kubectl create secret generic mon-secret \
  --from-env-file=.env \
  --dry-run=client -o yaml \
  | kubeseal --cert cert.pem --format yaml > sealed-mon-secret.yaml

# ── VÉRIFICATION ──────────────────────────────────────────────────

# Voir les SealedSecrets dans le cluster
kubectl get sealedsecrets -A

# Voir si le controller a bien créé le Secret correspondant
kubectl get secrets -n app

# Voir les logs du controller (utile si le Secret n'est pas créé)
kubectl logs -n kube-system deployment/sealed-secrets-controller

# Voir les clés RSA disponibles
kubectl get secrets -n kube-system -l sealedsecrets.bitnami.com/sealed-secrets-key

# ── SAUVEGARDE ────────────────────────────────────────────────────

# Sauvegarder la clé privée (critique — stocker hors Git)
kubectl get secret -n kube-system \
  -l sealedsecrets.bitnami.com/sealed-secrets-key \
  -o yaml > sealed-secrets-master-key-BACKUP.yaml

# Restaurer la clé sur un nouveau cluster
kubectl apply -f sealed-secrets-master-key-BACKUP.yaml
kubectl rollout restart deployment sealed-secrets-controller -n kube-system
```

---

## État actuel du projet — déployé le 16 avril 2026

Sealed Secrets est **opérationnel** dans le cluster.

### Ce qui a été fait (commit `93a72bb`)

```
kubernetes/
├── sealed-secrets/
│   ├── sealed-secrets-cert.pem      ← clé publique RSA (commitable, safe)
│   ├── sealed-mysql-secret.yaml     ← credentials MySQL chiffrés
│   └── sealed-app-secret.yaml       ← APP_KEY Laravel chiffré
└── helm/kubequest-app/templates/
    ├── sealed-mysql-secret.yaml     ← déployé par ArgoCD → déchiffré → mysql-secret
    ├── sealed-app-secret.yaml       ← déployé par ArgoCD → déchiffré → app-secret
    └── (mysql-secret.yaml supprimé) ← l'ancien Secret en clair n'existe plus
```

**Vérification en live :**
```bash
# Voir les SealedSecrets dans le cluster
kubectl get sealedsecrets -A
# NAMESPACE   NAME           STATUS   SYNCED
# app         mysql-secret            True
# app         app-secret              True

# Voir les Secrets K8s créés par le controller
kubectl get secrets -n app
# NAME           TYPE     DATA
# mysql-secret   Opaque   4    ← créé depuis SealedSecret
# app-secret     Opaque   1    ← créé depuis SealedSecret

# Logs du controller confirmant le déchiffrement
# SealedSecret unsealed successfully  ← mysql-secret
# SealedSecret unsealed successfully  ← app-secret
```

---

## Ajouter un nouveau secret — procédure complète

### Cas 1 — Nouveau secret simple (une seule valeur)

```bash
# Exemple : ajouter un token d'API externe
kubectl create secret generic api-token-secret \
  --from-literal=token="mon_token_api_super_secret" \
  --dry-run=client -o yaml \
  | kubeseal \
    --cert kubernetes/sealed-secrets/sealed-secrets-cert.pem \
    --format yaml \
    --namespace app \
  > kubernetes/sealed-secrets/sealed-api-token-secret.yaml

# Copier dans les templates Helm
cp kubernetes/sealed-secrets/sealed-api-token-secret.yaml \
   kubernetes/helm/kubequest-app/templates/

# Commiter
git add kubernetes/sealed-secrets/sealed-api-token-secret.yaml \
        kubernetes/helm/kubequest-app/templates/sealed-api-token-secret.yaml
git commit -m "feat(security): add sealed secret for api-token"
git push
# → ArgoCD détecte → applique → controller déchiffre → Secret créé dans le namespace app
```

### Cas 2 — Secret avec plusieurs valeurs

```bash
# Exemple : credentials d'un service externe (API key + endpoint + user)
kubectl create secret generic external-service-secret \
  --from-literal=api-key="ma_cle_api" \
  --from-literal=endpoint="https://api.example.com" \
  --from-literal=username="mon_user" \
  --dry-run=client -o yaml \
  | kubeseal \
    --cert kubernetes/sealed-secrets/sealed-secrets-cert.pem \
    --format yaml \
    --namespace app \
  > kubernetes/sealed-secrets/sealed-external-service-secret.yaml
```

### Cas 3 — Modifier une valeur existante (ex: rotation de mot de passe)

```bash
# 1. Mettre à jour values-secrets.yaml (gitignored) avec le nouveau mot de passe
vim kubernetes/helm/kubequest-app/values-secrets.yaml

# 2. Rechiffrer UNIQUEMENT le secret concerné
kubectl create secret generic mysql-secret \
  --from-literal=mysql-password="NOUVEAU_MOT_DE_PASSE" \
  --from-literal=mysql-root-password="NOUVEAU_ROOT_PASSWORD" \
  --from-literal=mysql-database="app_database" \
  --from-literal=mysql-user="app_user" \
  --dry-run=client -o yaml \
  | kubeseal \
    --cert kubernetes/sealed-secrets/sealed-secrets-cert.pem \
    --format yaml \
    --namespace app \
  > kubernetes/sealed-secrets/sealed-mysql-secret.yaml

# 3. Mettre à jour dans les templates
cp kubernetes/sealed-secrets/sealed-mysql-secret.yaml \
   kubernetes/helm/kubequest-app/templates/

# 4. Commiter → ArgoCD détecte le changement → rolling restart automatique
git add .
git commit -m "security: rotate mysql password"
git push
```

> **Note** : le controller détecte la mise à jour du SealedSecret et recrée le Secret K8s. Les pods qui montent ce Secret en `envFrom` récupèrent les nouvelles valeurs après un `rollout restart`.

### Cas 4 — Secret pour un namespace différent

```bash
# Les SealedSecrets sont liés au namespace par défaut (scope strict)
# Pour chiffrer pour un autre namespace :
kubectl create secret generic mon-secret \
  --from-literal=password="valeur" \
  --dry-run=client -o yaml \
  | kubeseal \
    --cert kubernetes/sealed-secrets/sealed-secrets-cert.pem \
    --format yaml \
    --namespace monitoring \     # ← namespace cible
  > kubernetes/sealed-secrets/sealed-mon-secret-monitoring.yaml

# Ce fichier ne peut être déchiffré QUE dans le namespace monitoring
```

### Cas 5 — Régénérer la clé publique (après reboot cluster)

La clé publique `sealed-secrets-cert.pem` reste valide tant que le controller tourne dans `kube-system`. Si tu refais le cluster from scratch, il faut régénérer :

```bash
# Récupérer la nouvelle clé publique
kubeseal --fetch-cert \
  --controller-name=sealed-secrets-controller \
  --controller-namespace=kube-system \
  > kubernetes/sealed-secrets/sealed-secrets-cert.pem

# Rechiffrer TOUS les secrets avec la nouvelle clé (obligatoire si nouvelle clé privée)
bash kubernetes/scripts/setup-sealed-secrets.sh

# Commiter la nouvelle clé publique + les nouveaux SealedSecrets
git add kubernetes/sealed-secrets/
git commit -m "security: rotate sealed secrets after cluster rebuild"
git push
```

---

## Utiliser les Secrets dans les pods

Une fois le SealedSecret déployé et le Secret K8s créé par le controller, les pods y accèdent normalement :

```yaml
# Dans un Deployment — injecter toutes les clés d'un Secret comme variables d'environnement
envFrom:
  - secretRef:
      name: mysql-secret     # le nom du Secret K8s créé par le controller (pas du SealedSecret)

# Dans un Deployment — injecter une seule clé
env:
  - name: DB_PASSWORD
    valueFrom:
      secretKeyRef:
        name: mysql-secret
        key: mysql-password

# Comme volume (pour des fichiers comme des certificats)
volumes:
  - name: tls-cert
    secret:
      secretName: tls-secret
```

**Dans notre app Laravel** (`kubernetes/helm/kubequest-app/templates/app.yaml`) :
```yaml
# APP_KEY est injecté depuis app-secret
- name: APP_KEY
  valueFrom:
    secretKeyRef:
      name: app-secret
      key: app-key

# Les credentials MySQL sont injectés depuis mysql-secret
envFrom:
  - secretRef:
      name: mysql-secret
```
