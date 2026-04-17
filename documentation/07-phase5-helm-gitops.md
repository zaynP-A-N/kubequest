# Phase 5 — Helm + GitOps (ArgoCD)

## Objectif

Passer d'un déploiement **manuel** (`kubectl apply -f`) à un déploiement **automatisé et versionné** :
- **Helm** : packager nos manifests en chart réutilisable et paramétrable
- **ArgoCD** : synchroniser automatiquement le cluster depuis Git (GitOps)

---

## 1. Helm — Pourquoi et comment

### Problème avec `kubectl apply -f`

Avec `kubectl apply`, si on veut déployer la même app dans 3 environnements (dev, staging, prod) avec des configurations différentes (ex: 1 réplica en dev, 5 en prod), on doit maintenir **3 copies de manifests YAML**. Toute modification demande 3 changements.

### La solution Helm

Helm est le **gestionnaire de packages Kubernetes**. Il transforme les manifests en **templates** avec des variables.

```
values.yaml (variables)     +     templates/*.yaml (manifests avec placeholders)
        │                                        │
        └──────────────────┬─────────────────────┘
                           │ helm install
                           ▼
              Manifests YAML finaux → kubectl apply
```

### Terminologie Helm

| Terme      | Définition                                                           |
|------------|----------------------------------------------------------------------|
| Chart      | Le package Helm (dossier avec Chart.yaml + values.yaml + templates/) |
| Release    | Une instance d'un chart installée sur le cluster                     |
| Values     | Les variables du chart (values.yaml, surchargeables à l'install)     |
| Repository | Un serveur qui héberge des charts (comme apt, npm, pip)              |
| Revision   | Une version d'une release (s'incrémente à chaque `helm upgrade`)     |

### Notre structure de chart

```
kubernetes/helm/kubequest-app/
├── Chart.yaml              # métadonnées du chart (nom, version, appVersion)
├── values.yaml             # valeurs par défaut (modifiables sans changer les templates)
└── templates/
    ├── namespace.yaml      # Namespace "app"
    ├── mysql-secret.yaml   # Secret MySQL (base64 via fonction Helm b64enc)
    ├── mysql.yaml          # PVC + Deployment + Service MySQL
    └── app.yaml            # Deployment + Service + Ingress Laravel
```

---

## 2. Syntaxe Helm — les bases

### Variables dans les templates

```yaml
# Template (templates/app.yaml)
image: "{{ .Values.app.image.repository }}:{{ .Values.app.image.tag }}"
replicas: {{ .Values.app.replicas }}
name: {{ .Chart.Name }}       # variable built-in : nom du chart
```

```yaml
# values.yaml — ce qui remplace {{ .Values.xxx }}
app:
  image:
    repository: mistererson/kubequest-app
    tag: latest
  replicas: 2
```

**Résultat rendu :**
```yaml
image: "mistererson/kubequest-app:latest"
replicas: 2
name: kubequest-app
```

### Fonctions utiles

```yaml
# Encode en base64 (pour les Secrets)
{{ .Values.mysql.credentials.password | b64enc | quote }}
# REDACTED_DB_PASSWORD → "<valeur-base64>"

# Indente un bloc YAML (pour les resources CPU/RAM)
resources:
  {{- toYaml .Values.app.resources | nindent 12 }}
# Le tiret dans {{- empêche d'ajouter une ligne vide avant

# Condition : n'inclut l'Ingress que si ingress.enabled=true
{{- if .Values.ingress.enabled }}
apiVersion: networking.k8s.io/v1
kind: Ingress
...
{{- end }}
```

---

## 3. Commandes Helm utilisées

### Vérifier la syntaxe du chart

```bash
helm lint kubernetes/helm/kubequest-app/
```

Vérifie :
- La structure des fichiers
- La syntaxe YAML des templates
- Les bonnes pratiques (ex: icon recommandé dans Chart.yaml)

Sortie :
```
==> Linting .
[INFO] Chart.yaml: icon is recommended
1 chart(s) linted, 0 chart(s) failed
```

### Voir le rendu des templates sans déployer

```bash
helm template kubequest kubernetes/helm/kubequest-app/
```

Génère les YAML finaux en substituant les variables, sans rien appliquer au cluster. Utile pour débugger et voir ce que Helm va vraiment créer.

### Installer le chart

```bash
helm install kubequest-app kubernetes/helm/kubequest-app/ \
  --namespace app \
  --create-namespace
```

| Option             | Rôle                                                        |
|--------------------|-------------------------------------------------------------|
| `kubequest-app`    | Nom de la **release** (instance du chart)                   |
| `--namespace app`  | Namespace où Helm stocke ses métadonnées                    |
| `--create-namespace` | Crée le namespace s'il n'existe pas                       |

### Surcharger des valeurs au déploiement

```bash
# Surcharger une valeur unique
helm install kubequest-app . --set app.replicas=3

# Surcharger avec un fichier de values alternatif
helm install kubequest-app . -f values-prod.yaml
```

C'est le principe des **environnements** : un seul chart, plusieurs fichiers de values.

### Voir les releases installées

```bash
helm list -n app
# NAME            NAMESPACE  REVISION  STATUS    CHART                  APP VERSION
# kubequest-app   app        1         deployed  kubequest-app-0.1.0    1.0.0
```

### Mettre à jour une release (rolling update)

```bash
# Changer l'image tag
helm upgrade kubequest-app . --set app.image.tag=v1.1.0 -n app
# → REVISION passe à 2, rolling update automatique
```

### Rollback

```bash
helm rollback kubequest-app 1 -n app   # revient à la revision 1
helm history kubequest-app -n app      # voir toutes les revisions
```

### Désinstaller

```bash
helm uninstall kubequest-app -n app
# Supprime toutes les ressources K8s créées par ce chart + les métadonnées Helm
```

---

## 4. ArgoCD — GitOps

### Qu'est-ce que le GitOps ?

**GitOps** = Git est la **source de vérité unique** pour l'état du cluster.

Principe :
1. On modifie un fichier dans Git (chart Helm, valeur, image tag)
2. ArgoCD détecte le changement (polling toutes les 3 minutes ou webhook)
3. ArgoCD applique automatiquement les changements sur le cluster
4. Si quelqu'un modifie manuellement une ressource K8s, ArgoCD la **revert**

```
Développeur → git push → GitLab
                 ↓
         ArgoCD (détecte le diff)
                 ↓
         kubectl apply automatique
                 ↓
    Cluster K8s mis à jour ✅
```

### Architecture ArgoCD

ArgoCD s'installe sur le cluster lui-même et tourne dans le namespace `argocd` :

```
namespace: argocd
├── argocd-server              ← UI Web + API (port 443)
├── argocd-application-controller  ← reconciliation loop principale
├── argocd-repo-server         ← clone et lit les repos Git
├── argocd-dex-server          ← authentification OIDC (SSO)
├── argocd-redis               ← cache
└── argocd-applicationset-controller  ← génère des Application automatiquement
```

### Installation d'ArgoCD

```bash
# Créer le namespace
kubectl create namespace argocd

# Appliquer les manifests officiels (contient ~1000 lignes de YAML)
kubectl apply -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

### Récupérer le mot de passe admin initial

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 --decode && echo
# → REDACTED_ARGOCD_PASSWORD
```

ArgoCD génère un mot de passe aléatoire au premier démarrage et le stocke dans ce Secret. En prod on le change immédiatement avec `argocd account update-password`.

### Exposer l'UI ArgoCD en NodePort

```bash
kubectl patch svc argocd-server -n argocd \
  -p '{"spec":{"type":"NodePort","ports":[
    {"port":80,"targetPort":8080,"nodePort":30088,"name":"http"},
    {"port":443,"targetPort":8080,"nodePort":30089,"name":"https"}
  ]}}'
```

Accès depuis le Mac via tunnel SSH :
```bash
# Créer le tunnel
ssh -L 30089:localhost:30089 node-1 -N -f

# Ouvrir dans le navigateur
open https://localhost:30089
# Login: admin / REDACTED_ARGOCD_PASSWORD
```

---

## 5. Configurer l'accès au repo GitLab privé

ArgoCD doit pouvoir cloner notre repo GitLab. Le token ne doit JAMAIS être dans un fichier commité dans Git — on le passe via un Secret K8s :

```bash
kubectl create secret generic gitlab-repo-creds \
  --namespace argocd \
  --from-literal=type=git \
  --from-literal=url=https://gitlab.com/fotsodjeff/t-clo-902_msc2026.git \
  --from-literal=username=fotsodjeff \
  --from-literal=password=<GITLAB_TOKEN>

# Le label dit à ArgoCD que ce Secret contient des credentials de repo
kubectl label secret gitlab-repo-creds \
  -n argocd \
  argocd.argoproj.io/secret-type=repository
```

ArgoCD détecte automatiquement les Secrets labelisés `argocd.argoproj.io/secret-type=repository` et les utilise pour s'authentifier.

---

## 6. La ressource Application ArgoCD

```yaml
# kubernetes/argocd/application.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: kubequest-app
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io   # nettoyage cascade lors de la suppression
spec:
  project: default

  source:
    repoURL: https://gitlab.com/fotsodjeff/t-clo-902_msc2026.git
    targetRevision: feat/initializeKubertenese-djeff-v1   # branche suivie
    path: kubernetes/helm/kubequest-app                   # chemin du chart

    helm:
      releaseName: kubequest-app
      values: |
        app:
          replicas: 2     # surcharge du values.yaml

  destination:
    server: https://kubernetes.default.svc   # cluster local
    namespace: app

  syncPolicy:
    automated:
      prune: true      # supprime les resources qui n'existent plus dans Git
      selfHeal: true   # revert les modifications manuelles
    syncOptions:
      - CreateNamespace=true
```

**`syncPolicy.automated`** est ce qui rend tout "automagique" :
- `prune: true` : si on supprime un fichier de template dans Git, la ressource K8s est supprimée
- `selfHeal: true` : si quelqu'un fait un `kubectl scale deployment app --replicas=5`, ArgoCD remet 2 (valeur dans Git) dans les 3 minutes

### Appliquer la ressource Application

```bash
kubectl apply -f kubernetes/argocd/application.yaml
```

C'est **la seule commande manuelle** de tout le workflow GitOps. Tout le reste est automatique.

---

## 7. Statuts ArgoCD à connaître

```bash
kubectl get application -n argocd kubequest-app
# NAME            SYNC STATUS   HEALTH STATUS
# kubequest-app   Synced        Healthy
```

**SYNC STATUS :**
| Statut       | Signification                                             |
|--------------|-----------------------------------------------------------|
| `Synced`     | Cluster = Git (tout est à jour)                           |
| `OutOfSync`  | Diff détecté entre Git et le cluster (sync en attente)    |
| `Unknown`    | ArgoCD ne peut pas déterminer l'état                      |

**HEALTH STATUS :**
| Statut        | Signification                                            |
|---------------|----------------------------------------------------------|
| `Healthy`     | Tous les pods sont Ready, tous les services fonctionnent |
| `Progressing` | Déploiement en cours (pods en démarrage)                 |
| `Degraded`    | Pods en crash, PVC non bindé, etc.                       |
| `Suspended`   | Sync désactivé manuellement                              |

---

## 8. Workflow GitOps au quotidien

Désormais, pour déployer une nouvelle version de l'image :

```bash
# 1. Modifier la valeur dans values.yaml
# Avant : tag: latest
# Après : tag: v1.1.0

# 2. Commit + push
git add kubernetes/helm/kubequest-app/values.yaml
git commit -m "feat(app): upgrade image to v1.1.0"
git push origin feat/initializeKubertenese-djeff-v1

# 3. ArgoCD détecte le changement (dans les ~3 minutes)
#    et fait un rolling update automatiquement
```

**C'est tout.** Plus de `kubectl apply` en prod. Git est le seul point d'entrée.

---

## 9. Vérification finale

```bash
# État ArgoCD
kubectl get application -n argocd
# NAME            SYNC STATUS   HEALTH STATUS
# kubequest-app   Synced        Healthy

# Pods déployés par ArgoCD
kubectl get pods -n app
# NAME                   READY   STATUS    RESTARTS   AGE
# app-xxx   1/1   Running   0   88s
# app-xxx   1/1   Running   0   88s
# mysql-xxx 1/1   Running   0   88s

# Test de l'app
ssh node-1 curl -s http://localhost:30080/api/counter/add -H Host:app.kubequest.local
# → {"value":"1"}
ssh node-1 curl -s http://localhost:30080/api/counter/count -H Host:app.kubequest.local
# → {"value":"1"}
```

---

## 10. Accéder à l'UI ArgoCD (depuis le Mac)

```bash
# Ouvrir le tunnel SSH
ssh -L 30089:localhost:30089 node-1 -N -f

# Ouvrir le navigateur
open https://localhost:30089
```

- **Login** : `admin`
- **Mot de passe** : `REDACTED_ARGOCD_PASSWORD`

L'UI affiche :
- L'arbre de toutes les ressources (Deployment, Service, PVC, Ingress...)
- L'historique des syncs
- Un bouton "Sync" pour forcer une synchronisation immédiate
- Un bouton "Rollback" pour revenir à une revision précédente

---

## 11. Lab vs Entreprise

| Aspect                    | Lab                                     | Entreprise                                    |
|---------------------------|-----------------------------------------|-----------------------------------------------|
| Chart Helm                | Manuel, local                           | Chart versionnés dans un registry Helm (ChartMuseum, GitLab) |
| `values.yaml` par env     | Un seul fichier                         | `values-dev.yaml`, `values-staging.yaml`, `values-prod.yaml` |
| ArgoCD Application        | Un seul fichier à la main              | App-of-apps pattern ou ApplicationSet         |
| Branche Git ciblée        | Feature branch                          | `main` en prod, `develop` en staging          |
| Credentials GitLab secret | `kubectl create secret` manuel          | External Secrets Operator depuis Vault/AWS SM |
| Migrations DB             | `kubectl exec ... artisan migrate`      | Job K8s ou Argo Workflows                     |
| Sync ArgoCD               | Polling toutes les 3 min                | Webhook GitLab → sync instantané              |
| Accès ArgoCD UI           | NodePort + tunnel SSH                   | Ingress avec TLS + SAML/OIDC SSO              |
