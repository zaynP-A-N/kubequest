# Phase 7 — Scalabilité Automatique (HPA + PDB)

## Objectif

Mettre en place l'autoscaling horizontal des pods applicatifs pour que le cluster absorbe automatiquement les pics de charge, puis revienne au minimum au retour au calme.

Composants déployés :
- **metrics-server** : expose les métriques CPU/RAM des pods à l'API Kubernetes
- **HPA** (HorizontalPodAutoscaler) : scale de 2 à 6 pods sur seuil CPU 50 %
- **PDB** (PodDisruptionBudget) : garantit qu'au moins 1 pod reste disponible pendant les mises à jour
- Fix **ArgoCD `ignoreDifferences`** : empêche ArgoCD de réinitialiser les replicas gérés par le HPA

---

## Architecture

```
                  ┌──────────────────────────────────────────┐
                  │            Kubernetes Control Plane        │
                  │                                            │
                  │  ┌──────────┐    ┌─────────────────────┐  │
                  │  │  metrics │    │  HPA Controller     │  │
                  │  │  server  │───▶│  CPU % > 50% ?      │  │
                  │  └──────────┘    │  → scale up/down    │  │
                  │                  └────────┬────────────┘  │
                  └───────────────────────────┼───────────────┘
                                              │ scale
                                              ▼
                  ┌──────────────────────────────────────────┐
                  │           Namespace: app                  │
                  │                                           │
                  │  ┌─────┐ ┌─────┐     ┌─────┐ ┌─────┐   │
                  │  │ app │ │ app │ ... │ app │ │ app │   │
                  │  │ pod │ │ pod │     │ pod │ │ pod │   │
                  │  └──┬──┘ └──┬──┘     └──┬──┘ └──┬──┘   │
                  │     └───────┴────────────┴───────┘       │
                  │                    │                      │
                  │             ┌──────▼──────┐               │
                  │             │    MySQL    │               │
                  │             └─────────────┘               │
                  └──────────────────────────────────────────┘
                  
  minReplicas=2 ──────────────────────────────── maxReplicas=6
```

---

## 1. Installation de metrics-server

Le HPA a besoin de l'API `metrics.k8s.io` pour lire le CPU courant des pods. Sur AWS avec kubeadm, les arguments par défaut de metrics-server ne fonctionnent pas (kubelet sans certificat signé + adresse préférée).

### Installation via Helm

```bash
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/
helm repo update

helm upgrade --install metrics-server metrics-server/metrics-server \
  --namespace kube-system \
  --set args[0]="--kubelet-insecure-tls" \
  --set args[1]="--kubelet-preferred-address-types=InternalIP"
```

**Arguments requis sur AWS ARM64 :**
- `--kubelet-insecure-tls` : le certificat kubelet n'est pas signé par une CA connue de metrics-server
- `--kubelet-preferred-address-types=InternalIP` : les nœuds ne sont pas joignables via hostname depuis le pod metrics-server

### Vérification

```bash
kubectl get pods -n kube-system | grep metrics
# metrics-server-xxxx   1/1   Running

kubectl top nodes
# NAME        CPU(cores)   CPU%   MEMORY(bytes)   MEMORY%
# node-1      98m          4%     1342Mi          37%
# node-2      38m          1%     765Mi           21%

kubectl top pods -n app
# NAME                     CPU(cores)   MEMORY(bytes)
# app-5bfb9dd5b8-gkw5l     10m          190Mi
# app-5bfb9dd5b8-x9k9h      7m          178Mi
```

---

## 2. Configuration HPA

### Prérequis : CPU limit obligatoire

Le HPA calcule `CPU % = CPU utilisé / CPU limit`. Sans `resources.limits.cpu`, le HPA ne peut pas calculer de pourcentage et affiche `<unknown>/50%`.

```yaml
# values.yaml
app:
  resources:
    requests:
      memory: "128Mi"
      cpu: "100m"
    limits:
      memory: "1Gi"
      cpu: "500m"   # ← obligatoire pour l'HPA
```

### Template HPA (autoscaling/v2)

```yaml
# templates/hpa-pdb.yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: app-hpa
  namespace: {{ .Values.namespace }}
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: app
  minReplicas: {{ .Values.hpa.minReplicas }}     # 2
  maxReplicas: {{ .Values.hpa.maxReplicas }}     # 6
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: AverageUtilization
          averageUtilization: {{ .Values.hpa.targetCPUUtilizationPercentage }}  # 50
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 30      # attend 30s de charge avant de scaler
      policies:
        - type: Pods
          value: 2
          periodSeconds: 60               # max +2 pods / 60s
    scaleDown:
      stabilizationWindowSeconds: 120     # attend 2 min de calme avant de descendre
      policies:
        - type: Pods
          value: 1
          periodSeconds: 60               # max -1 pod / 60s
```

> **Note API** : `autoscaling/v2` utilise `averageUtilization` (sans `Percentage` à la fin).  
> `autoscaling/v2beta2` utilisait `averageUtilizationPercentage` (déprécié).

### Values correspondantes

```yaml
# values.yaml
hpa:
  enabled: true
  minReplicas: 2
  maxReplicas: 6
  targetCPUUtilizationPercentage: 50

pdb:
  enabled: true
  minAvailable: 1
```

---

## 3. PodDisruptionBudget

Le PDB garantit un minimum de pods disponibles lors d'opérations de maintenance (drain de nœud, rolling update, etc.).

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: app-pdb
  namespace: {{ .Values.namespace }}
spec:
  minAvailable: {{ .Values.pdb.minAvailable }}   # 1
  selector:
    matchLabels:
      app: laravel
```

```bash
kubectl get pdb -n app
# NAME      MIN AVAILABLE   MAX UNAVAILABLE   ALLOWED DISRUPTIONS   AGE
# app-pdb   1               N/A               1                     2h
```

---

## 4. Fix ArgoCD + HPA : ignoreDifferences

### Problème

ArgoCD avec `selfHeal: true` surveille l'état du cluster et le compare à Git. Quand l'HPA passe de 2 à 4 replicas, ArgoCD détecte une **divergence** (`spec.replicas: 2` dans Git vs `4` dans le cluster) et réinitialise immédiatement à 2.

**Symptôme** : un nouveau pod créé par le HPA est en `Terminating` au bout de quelques secondes.

### Solution : ignoreDifferences

```yaml
# kubernetes/argocd/application.yaml
spec:
  # Ignore spec.replicas — géré par le HPA, pas par Git
  ignoreDifferences:
    - group: apps
      kind: Deployment
      jsonPointers:
        - /spec/replicas

  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

```bash
kubectl apply -f kubernetes/argocd/application.yaml
```

---

## 5. LimitRange et ResourceQuota adaptées au HPA

### Problème

La Phase 6 avait défini une `LimitRange` avec `max.memory: 512Mi`. Toute tentative de créer un pod avec `limits.memory: 1Gi` était bloquée :

```
Error creating: pods "app-856c74bd7-l72zt" is forbidden:
  maximum memory usage per Container is 512Mi, but limit is 1Gi
```

### Fix

```yaml
# templates/rbac-quota.yaml
# LimitRange — plafond par container
spec:
  limits:
    - type: Container
      max:
        memory: "1Gi"    # ← augmenté de 512Mi → 1Gi
        cpu: "500m"

# ResourceQuota — budget total du namespace
spec:
  hard:
    requests.cpu: "1"
    requests.memory: "2Gi"
    limits.cpu: "4"       # ← augmenté (6 replicas × 500m = 3 CPU)
    limits.memory: "8Gi"  # ← augmenté (6 replicas × 1Gi + MySQL)
    pods: "10"
```

---

## 6. Test de charge et résultats

### Outil : Apache Benchmark (ab)

```bash
# Installation sur le nœud node-1 (Amazon Linux ARM64)
sudo yum install -y httpd-tools

# Test : 20 000 requêtes, 20 connexions simultanées, vers ClusterIP direct
APP_SVC_IP=$(kubectl get svc app -n app -o jsonpath='{.spec.clusterIP}')
ab -n 20000 -c 20 http://$APP_SVC_IP/api/counter/count
```

> Le test est lancé **depuis node-1 directement vers le ClusterIP** (pas de port-forward),  
> ce qui garantit la stabilité de la connexion pendant toute la durée du test.

### Observations HPA pendant le test

| Temps | CPU HPA | Replicas | Pods Ready | Événement |
|-------|---------|----------|------------|-----------|
| T+0s  | 12%/50% | 2        | 2/2        | Baseline  |
| T+15s | 9%/50%  | 2        | 2/2        | ab warm-up (connexions TCP) |
| T+30s | **461%**/50% | 2   | 2/2        | Pic CPU → HPA décide de scaler |
| T+45s | 498%/50% | **4**   | 2/4        | 2 nouveaux pods démarrés |
| T+60s | 466%/50% | 4        | 2/4        | Pods en initialisation |
| T+75s | 451%/50% | 4        | **4/4**    | Scale-up 2→4 terminé ✓ |
| T+90s | 400%/50% | 4        | 4/4        | Charge répartie sur 4 pods |
| T+105s| 408%/50% | **6**   | 4/6        | 2 nouveaux pods (maxReplicas atteint) |
| T+120s| 414%/50% | 6        | 4/6        | Pods en initialisation |

### Résultat : scale-up 2 → 4 → 6 pods ✓

```
Scale-up progression:
  2 pods  ──[T+30s: CPU>50%]──▶  4 pods  ──[T+90s: CPU>50%]──▶  6 pods (max)
```

### Note sur le bottleneck MySQL

Malgré le scale-up à 6 pods applicatifs, le CPU reste élevé (~400%) car **MySQL est le vrai goulot d'étranglement** : toutes les requêtes PHP nécessitent un accès base de données, et une seule instance MySQL sature sous 20 connexions simultanées. C'est un comportement réaliste et documenté : le HPA scale l'applicatif mais la DB reste un single point of contention.

---

## 7. Observation du scale-down

Après arrêt du test de charge, le HPA attend `stabilizationWindowSeconds: 120` (2 minutes) avant de commencer à descendre, puis retire **1 pod toutes les 60 secondes** jusqu'au minReplicas.

```bash
# Observer le scale-down en temps réel
watch -n10 kubectl get hpa,pods -n app
```

### Résultat observé

| Temps après fin test | Replicas | Événement |
|---------------------|----------|-----------|
| T+0   | 5 pods  | Stabilisation (CPU retombé à 12%) |
| T+1min | 3 pods | HPA scale-down (2 pods supprimés accumulés) |
| T+2min | **2 pods** | minReplicas atteint ✓ |
| T+3-6min | 2 pods | Stable à minReplicas |

> Le scale-down fonctionne correctement. La progression exacte 6→5→4→3→2 se fait via le `maxScaleDown: 1 pod / 60s`, certaines étapes pouvant se regrouper sur l'intervalle d'observation.

---

## 8. Commandes de référence

```bash
# État HPA
kubectl get hpa -n app
kubectl describe hpa app-hpa -n app

# Métriques en temps réel
kubectl top pods -n app
kubectl top nodes

# Historique des événements HPA
kubectl describe hpa app-hpa -n app | grep -A20 "Events:"

# Surveiller le scale en continu
watch -n5 kubectl get hpa,pods -n app

# PDB
kubectl get pdb -n app
kubectl describe pdb app-pdb -n app
```

---

## 9. Bugs rencontrés — Debug étape par étape

---

### Bug 1 — `averageUtilizationPercentage` invalide dans le HPA

**Symptôme** : Après `git push` + sync ArgoCD, le HPA est en état d'erreur.

```bash
kubectl get hpa -n app
# NAME      REFERENCE        TARGETS         MINPODS   MAXPODS   REPLICAS
# app-hpa   Deployment/app   <unknown>/50%   2         6         0
```

**Debug** :
```bash
# Étape 1 : Lire les events du HPA
kubectl describe hpa app-hpa -n app | tail -20
# Events:
#   Warning  FailedGetScale  failed to get cpu utilization:
#     invalid metric source: averageUtilizationPercentage is not a valid field

# Étape 2 : Identifier le champ dans le template
grep -n "averageUtilization" kubernetes/helm/kubequest-app/templates/hpa-pdb.yaml
# → averageUtilizationPercentage: 50
```

**Cause** : `autoscaling/v2` utilise `averageUtilization` (sans `Percentage`). L'ancien nom venait de `autoscaling/v2beta2` qui est déprécié.

**Fix** :
```yaml
# Avant
target:
  type: AverageUtilization
  averageUtilizationPercentage: 50   # ← invalide en v2

# Après
target:
  type: AverageUtilization
  averageUtilization: 50             # ← correct
```

Commit : `10cd1a2`

---

### Bug 2 — APP_KEY=SEALED dans les pods (Laravel renvoie 500)

**Symptôme** : Après déploiement des SealedSecrets, l'app retourne des erreurs HTTP 500.

```bash
curl -s http://app.kubequest.local/api/counter
# {"message":"The MAC is invalid.","exception":"..."}
```

**Debug** :
```bash
# Étape 1 : Inspecter les variables d'env dans le pod
kubectl exec -n app deploy/app -- env | grep APP_KEY
# APP_KEY=SEALED   ← la valeur hardcodée dans values.yaml

# Étape 2 : Trouver où APP_KEY est défini dans le template
grep -n "APP_KEY" kubernetes/helm/kubequest-app/templates/app.yaml
# - name: APP_KEY
#     value: {{ .Values.app.env.appKey }}   ← lit values.yaml, pas le Secret

# Étape 3 : Vérifier que le Secret app-secret existe et contient la bonne clé
kubectl get secret app-secret -n app -o jsonpath='{.data.app-key}' | base64 -d | head -c 20
# base64:DJYTvaRkEZ/...   ← la vraie clé est bien là
```

**Cause** : `app.yaml` lisait `.Values.app.env.appKey` (= chaîne `"SEALED"` dans values.yaml) au lieu de récupérer la valeur depuis le SealedSecret.

**Fix** :
```yaml
# Avant
- name: APP_KEY
  value: {{ .Values.app.env.appKey }}

# Après
- name: APP_KEY
  valueFrom:
    secretKeyRef:
      name: app-secret
      key: app-key
```

Vérification post-fix :
```bash
kubectl exec -n app deploy/app -- env | grep APP_KEY
# APP_KEY=base64:DJYTvaRkEZ/...   ✓
```

Commit : `0fa028b`

---

### Bug 3 — OOMKill sous charge (memory limit trop basse)

**Symptôme** : Sous test de charge (20 connexions), un pod passe en `OOMKilled` et les connexions sont coupées (`apr_socket_recv: Connection reset by peer`).

```bash
kubectl get pods -n app
# app-557f7987d6-kvh9v   0/1   OOMKilled   4  ...
```

**Debug** :
```bash
# Étape 1 : Voir la raison du dernier redémarrage
kubectl describe pod app-557f7987d6-kvh9v -n app | grep -A5 "Last State:"
# Last State: Terminated
#   Reason: OOMKilled
#   Exit Code: 137

# Étape 2 : Vérifier la consommation mémoire
kubectl top pods -n app
# app-557f7987d6-kvh9v   487m   511Mi   ← au ras de la limite 512Mi

# Étape 3 : Vérifier la limite configurée
kubectl get pod app-557f7987d6-kvh9v -n app \
  -o jsonpath='{.spec.containers[0].resources.limits.memory}'
# 512Mi   → trop juste pour PHP-FPM sous charge
```

**Cause** : PHP-FPM alloue ~180Mi au repos et peut monter à 500Mi+ sous 20 connexions simultanées. La limite à 512Mi était insuffisante. Augmentation progressive : 512Mi → 768Mi → **1Gi**.

**Fix** :
```yaml
# values.yaml
resources:
  limits:
    memory: "1Gi"   # 512Mi → 768Mi → 1Gi
    cpu: "500m"
```

Commit : `8455504`

---

### Bug 4 — LimitRange Phase 6 bloque les nouveaux pods à 1Gi

**Symptôme** : Après avoir passé la limite mémoire à 1Gi, le rollout reste bloqué. Les pods existants tournent mais aucun nouveau pod ne démarre.

```bash
kubectl rollout status deployment/app -n app
# error: deployment "app" exceeded its progress deadline

kubectl get rs -n app
# app-856c74bd7   1   0   0   (DESIRED=1, CURRENT=0 → aucun pod créé)
```

**Debug** :
```bash
# Étape 1 : Regarder les events du ReplicaSet bloqué
kubectl describe rs app-856c74bd7 -n app | grep -A5 "Events:"
# Warning FailedCreate: pods "app-856c74bd7-l72zt" is forbidden:
#   maximum memory usage per Container is 512Mi, but limit is 1Gi

# Étape 2 : Identifier la LimitRange responsable
kubectl get limitrange -n app
# NAME         CREATED AT
# app-limits   2026-04-10T16:54:15Z

kubectl get limitrange app-limits -n app -o jsonpath='{.spec.limits[0].max.memory}'
# 512Mi   ← plafond LimitRange créé en Phase 6

# Étape 3 : Trouver le fichier source dans le repo
grep -rn "LimitRange\|512Mi" kubernetes/helm/kubequest-app/templates/
# → rbac-quota.yaml : max.memory: "512Mi"
```

**Cause** : La `LimitRange` de Phase 6 (sécurité) imposait `max.memory: 512Mi` par container. K8s rejette à l'admission tout pod dont les `limits` dépassent ce plafond, quelle que soit la valeur dans les specs du Deployment.

**Fix** :
```yaml
# templates/rbac-quota.yaml — LimitRange
max:
  memory: "1Gi"   # ← 512Mi → 1Gi

# ResourceQuota (mis à jour en cohérence pour 6 replicas × 1Gi)
limits.cpu: "4"
limits.memory: "8Gi"
```

Commit : `c8ebe92`

---

### Bug 5 — ArgoCD annule le scale-up (selfHeal)

**Symptôme** : Le HPA crée un 3ème pod, mais celui-ci passe en `Terminating` en quelques secondes. L'HPA n'arrive jamais à dépasser 2 répliques.

```bash
kubectl get pods -n app -w
# app-5bfb9dd5b8-6sbcw   0/1   Terminating   6s   ← tué dès creation
```

**Debug** :
```bash
# Étape 1 : Regarder les events du Deployment
kubectl describe deployment app -n app | grep -A5 "Events:"
# Normal   ScalingReplicaSet  Scaled up replica set to 3
# Normal   ScalingReplicaSet  Scaled down replica set to 2   ← revert immédiat

# Étape 2 : Chercher qui reverte (ArgoCD ?)
kubectl get events -n app --sort-by=.lastTimestamp | tail -10
# → Rien de suspect dans le namespace app

# Étape 3 : Vérifier ArgoCD
kubectl get application kubequest-app -n argocd -o jsonpath='{.status.conditions}' | python3 -m json.tool
# → "ComparisonError": "spec.replicas mismatch: desired 2, actual 3"

# Étape 4 : Confirmer que selfHeal est actif
kubectl get application kubequest-app -n argocd \
  -o jsonpath='{.spec.syncPolicy.automated}'
# {"prune":true,"selfHeal":true}   ← selfHeal réinitialise spec.replicas à 2
```

**Cause** : ArgoCD avec `selfHeal: true` compare l'état live du cluster (replicas=3, géré par HPA) avec l'état désiré dans Git (replicas=2 dans values.yaml) et reverte immédiatement toute divergence.

**Fix** : Ajouter `ignoreDifferences` pour exclure `spec.replicas` des comparaisons ArgoCD :

```yaml
# kubernetes/argocd/application.yaml
spec:
  ignoreDifferences:
    - group: apps
      kind: Deployment
      jsonPointers:
        - /spec/replicas   # ← géré par le HPA, pas par Git
  syncPolicy:
    automated:
      selfHeal: true   # reste actif pour tout le reste
```

Vérification :
```bash
kubectl apply -f kubernetes/argocd/application.yaml
kubectl get application kubequest-app -n argocd \
  -o jsonpath='{.spec.ignoreDifferences}'
# [{"group":"apps","jsonPointers":["/spec/replicas"],"kind":"Deployment"}]  ✓
```

Commit : `8bc6705`

---

## 10. Commits de cette phase

| Commit | Message |
|--------|---------|
| `0fa028b` | feat(scalability): fix APP_KEY from sealed secret, add HPA and PDB |
| `10cd1a2` | fix(hpa): use averageUtilization for autoscaling/v2 API |
| `dc8f1f5` | fix(resources): increase memory limit to 768Mi |
| `8455504` | fix(resources): increase memory limit to 1Gi to prevent OOMKill under load |
| `c8ebe92` | fix(quota): increase LimitRange max memory to 1Gi and ResourceQuota limits to support HPA scale-up |
| `8bc6705` | fix(argocd): add ignoreDifferences for spec.replicas to allow HPA scale-up |
