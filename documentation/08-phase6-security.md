# Phase 6 — Security Hardening Kubernetes

## Objectif

Appliquer les **bonnes pratiques de sécurité Kubernetes** sur le namespace `app` :
1. **NetworkPolicy** — contrôle du trafic réseau entre pods
2. **SecurityContext** — conteneurs non-root, capabilities minimales
3. **ServiceAccount** — identité minimale pour les pods
4. **ResourceQuota + LimitRange** — limites de consommation

---

## Pourquoi sécuriser un cluster Kubernetes ?

Par défaut, Kubernetes est **permissif** :
- Tous les pods peuvent communiquer avec tous les autres pods
- Les conteneurs tournent en root (UID 0)
- Un conteneur peut escalader ses privilèges (sudo, setuid)
- Il n'y a pas de limite à ce qu'un namespace peut consommer

Ces défauts violent plusieurs principes de sécurité :
- **Principe du moindre privilège** : chaque composant ne doit avoir que les droits strictement nécessaires
- **Defense in depth** : si un pods est compromis, l'attaquant ne doit pas pouvoir atteindre le reste du cluster

Les 4 mesures qu'on a appliquées couvrent les éléments les plus critiques de l'**OWASP Top 10 for Kubernetes**.

---

## 1. NetworkPolicy — Contrôle du trafic réseau

### Le problème sans NetworkPolicy

Sans règle réseau, si un attaquant compromet un pod quelconque dans le cluster (ex: un pod frontend dans un autre namespace), il peut :
```
pod-piraté → mysql.app.svc.cluster.local:3306 → CONNEXION RÉUSSIE
```
Il peut alors lire ou modifier toutes les données MySQL.

### La solution — 5 règles en cascade

```
Règle 1 : default-deny-all        → bloque TOUT par défaut
Règle 2 : mysql-allow-from-app    → MySQL accessible SEULEMENT depuis les pods Laravel
Règle 3 : app-allow-ingress       → app accepte HTTP depuis l'Ingress Controller
Règle 4 : app-allow-egress        → app peut sortir vers MySQL + DNS
Règle 5 : mysql-allow-egress-dns  → MySQL peut faire des résolutions DNS
```

**La règle 1 est la plus importante.** Elle transforme le modèle par défaut ("tout est permis") en modèle restrictif ("tout est bloqué sauf ce qui est explicitement autorisé").

### Vérification

```bash
kubectl get networkpolicies -n app
# NAME                     POD-SELECTOR
# default-deny-all         <none>           ← s'applique à tous les pods
# mysql-allow-from-app     app=mysql
# app-allow-ingress        app=laravel
# app-allow-egress         app=laravel
# mysql-allow-egress-dns   app=mysql
```

### Test de la NetworkPolicy (preuve que MySQL est isolé)

```bash
# Lancer un pod de test dans un autre namespace
kubectl run test --image=alpine -n default -it --rm -- sh

# Depuis ce pod, essayer de se connecter à MySQL
apk add mysql-client
mysql -h mysql.app.svc.cluster.local -u app_user -pREDACTED_DB_PASSWORD app_database
# → ERROR 2002 (HY000): Can't connect to server on 'mysql.app...' (110)
# → CONNEXION BLOQUÉE ✅
```

> **En entreprise** : les NetworkPolicies sont souvent gérées par l'équipe sécurité via un outil dédié comme Cilium (qui supporte des règles L7 — HTTP paths, gRPC methods) ou Calico Enterprise.

---

## 2. SecurityContext — Conteneurs non-root

### Le problème

Par défaut, les conteneurs Docker tournent en **root (UID 0)**. Si un attaquant exploite une faille de l'application, il se retrouve root à l'intérieur du conteneur. Avec certaines misconfiguration (`hostPID`, `hostNetwork`, `privileged`), cela peut devenir root sur le nœud.

### Ce qu'on a appliqué sur les pods Laravel

```yaml
# Au niveau du pod (s'applique à tous les conteneurs)
securityContext:
  runAsNonRoot: true       # K8s refuse de démarrer si le conteneur tente de tourner en root
  runAsUser: 33            # UID 33 = www-data (utilisateur Apache sur Debian)
  runAsGroup: 33
  fsGroup: 33              # groupe propriétaire des volumes montés

# Au niveau du conteneur
securityContext:
  allowPrivilegeEscalation: false   # interdit sudo, setuid, setgid
  capabilities:
    drop:
      - ALL                         # supprime TOUTES les capabilities Linux
    add:
      - NET_BIND_SERVICE            # ré-autorise uniquement le binding sur les ports < 1024 (port 80)
```

### Les Linux Capabilities — c'est quoi ?

Le kernel Linux divise les privilèges root en ~40 "capabilities" :
- `NET_BIND_SERVICE` : ouvrir un port < 1024
- `CHOWN` : changer le propriétaire d'un fichier
- `SYS_ADMIN` : opérations d'administration (montage, namespaces...)
- `NET_RAW` : créer des raw sockets (arp spoofing, etc.)

`drop: ALL` puis `add: NET_BIND_SERVICE` = on part de zéro et on n'autorise que ce qui est nécessaire.

### Ce qu'on a appliqué sur MySQL

MySQL a besoin de plus de capabilities car il gère lui-même ses fichiers de données :
```yaml
capabilities:
  drop:
    - ALL
  add:
    - CHOWN        # chown sur /var/lib/mysql
    - DAC_OVERRIDE # accéder aux fichiers malgré les permissions
    - SETGID
    - SETUID
```

### Vérification

```bash
# Vérifier que le pod tourne bien avec l'UID www-data
kubectl exec -n app deployment/app -- id
# uid=33(www-data) gid=33(www-data) groups=33(www-data)

# Vérifier les capabilities actives
kubectl exec -n app deployment/app -- cat /proc/1/status | grep Cap
```

---

## 3. ServiceAccount — Identité minimale

### Le problème

Par défaut, chaque pod reçoit le ServiceAccount `default` avec un **token JWT monté automatiquement** dans `/var/run/secrets/kubernetes.io/serviceaccount/token`. Ce token permet de faire des requêtes à l'API Kubernetes.

Si un attaquant compromet le pod Laravel, il peut utiliser ce token pour :
```bash
curl -H "Authorization: Bearer $(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" \
  https://kubernetes.default.svc/api/v1/namespaces
```

### La solution

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: app-sa
  namespace: app
automountServiceAccountToken: false   # ne monte PAS le token dans le pod
```

Laravel n'a aucune raison de parler à l'API Kubernetes → on désactive complètement ce mécanisme.

```yaml
# Dans le Deployment
spec:
  serviceAccountName: app-sa   # utilise notre SA "vide"
```

### Vérification

```bash
# Le token ne doit PAS être présent dans le pod
kubectl exec -n app deployment/app -- ls /var/run/secrets/ 2>&1
# ls: cannot access '/var/run/secrets/': No such file or directory ✅
```

---

## 4. ResourceQuota + LimitRange — Limites de consommation

### ResourceQuota — Limite globale du namespace

```yaml
spec:
  hard:
    requests.cpu: "1"          # total CPU request de tous les pods : max 1 vCPU
    requests.memory: "1Gi"     # total RAM request : max 1 Gi
    limits.cpu: "2"            # total CPU limit : max 2 vCPU
    limits.memory: "2Gi"       # total RAM limit : max 2 Gi
    pods: "10"                 # max 10 pods simultanés
    services: "5"              # max 5 Services
    persistentvolumeclaims: "3" # max 3 PVC
```

**Pourquoi ?** Sans quota, une faille dans l'app (ex: boucle infinie, memory leak) peut épuiser les ressources d'un nœud entier et impacter les autres applications du cluster (effet "noisy neighbor").

```bash
# Voir la consommation actuelle vs les limites
kubectl get resourcequota -n app
# REQUEST: pods: 3/10, requests.cpu: 450m/1, requests.memory: 512Mi/1Gi
# LIMIT: limits.cpu: 400m/2, limits.memory: 1536Mi/2Gi
```

### LimitRange — Valeurs par défaut pour les containers

```yaml
spec:
  limits:
    - type: Container
      default:            # si le container ne déclare pas de limits
        memory: "256Mi"
        cpu: "200m"
      defaultRequest:     # si le container ne déclare pas de requests
        memory: "64Mi"
        cpu: "50m"
      max:                # plafond absolu par container
        memory: "512Mi"
        cpu: "500m"
```

Sans LimitRange, un container sans `resources:` peut consommer 100% du CPU du nœud. Le LimitRange protège contre les containers mal configurés.

---

## 5. Résumé des protections appliquées

| Menace                              | Protection                              |
|-------------------------------------|-----------------------------------------|
| Pod compromis accède à MySQL        | NetworkPolicy `default-deny-all` + `mysql-allow-from-app` |
| Container tourne en root            | `runAsNonRoot: true`, `runAsUser: 33`   |
| Escalade de privilèges              | `allowPrivilegeEscalation: false`       |
| Capabilities dangereuses            | `drop: ALL` + `add` minimal             |
| Token K8s exposé dans le pod        | `automountServiceAccountToken: false`   |
| App monopolise les ressources       | `ResourceQuota` sur le namespace        |
| Container sans limites déclarées    | `LimitRange` avec valeurs par défaut    |

---

## 6. Bugs rencontrés et résolutions détaillées

### Bug 1 — ArgoCD `argocd-repo-server` en état `Unknown` + `argocd-applicationset-controller` en `CrashLoopBackOff`

#### Symptôme

Après le push du commit contenant les nouveaux fichiers `network-policies.yaml` et `rbac-quota.yaml`, ArgoCD n'a pas déclenché la synchronisation automatique. En vérifiant l'état du namespace `argocd` :

```bash
kubectl get pods -n argocd
```

```
NAME                                                READY   STATUS             RESTARTS
argocd-application-controller-0                     1/1     Running            0
argocd-applicationset-controller-69b4f8d4b5-xxx     0/1     CrashLoopBackOff   5
argocd-dex-server-xxxxxxxxxx-xxx                    1/1     Running            0
argocd-notifications-controller-xxxxxxxxxx-xxx      1/1     Running            0
argocd-redis-xxxxxxxxxx-xxx                         1/1     Running            0
argocd-repo-server-xxxxxxxxxx-xxx                   0/1     Unknown            0
argocd-server-xxxxxxxxxx-xxx                        1/1     Running            0
```

Deux pods critiques non fonctionnels :
- `argocd-repo-server` → responsable du clonage et de la lecture des Git repositories
- `argocd-applicationset-controller` → responsable du traitement des ressources ApplicationSet

Sans `argocd-repo-server`, ArgoCD ne peut **pas lire le contenu du repo Git** → impossible de générer les manifests → sync bloqué.

#### Diagnostic

```bash
# Lire les logs du repo-server pour comprendre pourquoi il est Unknown
kubectl logs -n argocd deployment/argocd-repo-server --previous
# → "Unknown" signifie souvent que le pod a été tué (OOMKilled ou eviction)
#    et que le précédent état n'a pas été nettoyé

# Lire les logs du applicationset-controller en CrashLoopBackOff
kubectl logs -n argocd deployment/argocd-applicationset-controller --previous
# → Erreur de connexion au repo-server (dépendance circulaire)
```

**Cause racine** : après un reboot des nœuds EC2 (ou un redémarrage de containerd), certains pods ArgoCD se retrouvent dans un état instable. L'état `Unknown` indique que le pod n'a pas été proprement terminé — le kubelet du nœud a perdu contact avec le pod avant de pouvoir mettre à jour son état. L'`applicationset-controller` crashe en boucle car il ne peut pas se connecter au `repo-server` qui est indisponible.

#### Résolution

Un simple `kubectl rollout restart` force Kubernetes à **supprimer les anciens pods et en créer de nouveaux propres** :

```bash
kubectl rollout restart deployment/argocd-repo-server -n argocd
# deployment.apps/argocd-repo-server restarted

kubectl rollout restart deployment/argocd-applicationset-controller -n argocd
# deployment.apps/argocd-applicationset-controller restarted
```

**Pourquoi `rollout restart` et pas `kubectl delete pod` ?**
- `kubectl delete pod` supprime UN pod, mais si on supprime le mauvais ou qu'il y a plusieurs replicas, on peut rater des pods
- `kubectl rollout restart deployment/<name>` déclenche un rolling update sur le Deployment entier → Kubernetes recrée proprement TOUS les pods du deployment, en respectant la stratégie de rolling update (no downtime)
- C'est la commande idiomatique recommandée pour forcer un redémarrage propre

#### Vérification après correction

```bash
# Attendre que les pods soient Ready
kubectl rollout status deployment/argocd-repo-server -n argocd
# Waiting for deployment "argocd-repo-server" rollout to finish: 0 of 1 updated replicas are available...
# deployment "argocd-repo-server" successfully rolled out

kubectl rollout status deployment/argocd-applicationset-controller -n argocd
# deployment "argocd-applicationset-controller" successfully rolled out

# Vérifier l'état final
kubectl get pods -n argocd
# Tous les pods doivent être 1/1 Running
```

#### Vérifier la sync ArgoCD après les redémarrages

```bash
kubectl get applications -n argocd
# NAME            SYNC STATUS   HEALTH STATUS
# kubequest-app   Synced        Healthy      ← ArgoCD a bien synchro les nouveaux fichiers
```

Si l'application reste en `OutOfSync`, forcer une synchronisation manuelle :

```bash
# Via CLI argocd (si installé)
argocd app sync kubequest-app

# Ou via kubectl en annotant l'application pour forcer un refresh
kubectl annotate application kubequest-app -n argocd \
  argocd.argoproj.io/refresh=hard --overwrite
```

#### Rolling update déclenché automatiquement

Une fois ArgoCD opérationnel, il a détecté les changements dans le repo (nouveaux fichiers + modifications des Deployments) et a déclenché un **rolling update** des pods Laravel :

```bash
kubectl get pods -n app -w
# NAME                   READY   STATUS              RESTARTS
# app-6d8f5bc7f-abc12    1/1     Running             0   ← ancien pod (sans securityContext)
# app-79f5b967bc-9rrsf   0/1     ContainerCreating   0   ← nouveau pod (avec securityContext)
# app-79f5b967bc-9rrsf   1/1     Running             0   ← nouveau pod prêt
# app-6d8f5bc7f-abc12    0/1     Terminating         0   ← ancien pod supprimé
# app-79f5b967bc-pm24s   0/1     ContainerCreating   0   ← deuxième nouveau pod
# app-79f5b967bc-pm24s   1/1     Running             0
# app-6d8f5bc7f-def34    0/1     Terminating         0
```

Le nouveau ReplicaSet `79f5b967bc` correspond aux pods avec les SecurityContexts appliqués.

---

### Bug 2 — Premier déploiement SecurityContext échoue : `container has runAsNonRoot and image will run as root`

#### Symptôme

Après le premier push des SecurityContext sur le Deployment `app`, les nouveaux pods refusaient de démarrer :

```bash
kubectl describe pod app-79f5b967bc-9rrsf -n app
# Events:
#   Warning  Failed   CreateContainerConfigError
#   Error: container has runAsNonRoot and image will run as root
#   (pod: "app-79f5b967bc-9rrsf_app"), container: app
```

#### Cause

L'image Docker `mistererson/kubequest-app:latest` avait son `USER` défini dans le Dockerfile. Si l'instruction `USER` dans le Dockerfile spécifie root (ou est absente — root par défaut), K8s refuse de démarrer le pod quand `runAsNonRoot: true` est positionné.

#### Résolution

Spécifier explicitement `runAsUser: 33` (UID de www-data sur Debian) :

```yaml
securityContext:
  runAsNonRoot: true
  runAsUser: 33    # ← UID explicite, K8s ne vérifie plus l'image mais force cet UID
  runAsGroup: 33
  fsGroup: 33
```

Avec `runAsUser: 33`, Kubernetes **overwrite** l'utilisateur défini dans l'image et démarre le processus avec l'UID 33. La combinaison `runAsNonRoot: true` + `runAsUser: 33` signifie : "tourne en tant que UID 33, et si jamais UID 33 = 0 (root), refuse de démarrer".

---

### Bug 3 — ResourceQuota bloque le déploiement : `exceeded quota`

#### Symptôme

Après avoir appliqué la ResourceQuota, un nouveau déploiement pouvait échouer avec :

```
Error creating: pods "app-xxx" is forbidden:
exceeded quota: app-quota,
requested: requests.memory=128Mi,
used: requests.memory=960Mi,
limited: requests.memory=1Gi
```

#### Cause

La ResourceQuota additionne les `requests` de tous les pods actifs. Pendant un rolling update, Kubernetes essaie de créer les nouveaux pods **avant** de supprimer les anciens (strategy `RollingUpdate`). Si les nouveaux pods + anciens pods dépassent le quota, le scheduler refuse de créer les nouveaux pods.

**Exemple** : 2 anciens pods (256Mi each = 512Mi) + 2 nouveaux pods tentent d'être créés (256Mi each = 512Mi) → total 1024Mi > 1Gi limite.

#### Résolution

Deux approches :

**Option A** (choisie) — Augmenter légèrement la quota pour absorber le rolling update :
```yaml
# Dans rbac-quota.yaml
requests.memory: "1500Mi"   # assez pour anciens + nouveaux pods en simultané
limits.memory: "2Gi"
```

**Option B** — Réduire les requests des containers pour rester dans le budget :
```yaml
# Dans values.yaml, ajuster resources
resources:
  requests:
    memory: "64Mi"   # plus petit = rolling update possible dans le quota
    cpu: "50m"
```

---

## 7. Ce qui manque encore (pour aller plus loin en prod)

| Mesure                        | Outil                        | Pourquoi                              |
|-------------------------------|-------------------------------|---------------------------------------|
| Secrets chiffrés dans Git     | Sealed Secrets / SOPS         | Les Secrets K8s en base64 ne sont pas chiffrés |
| Scan d'images                 | Trivy / Snyk                  | Détecter les CVE dans `mysql:8.0` ou `php:8.2` |
| Audit logs                    | Kubernetes Audit Policy       | Tracer tous les appels à l'API K8s    |
| Pod Security Admission        | PodSecurity (built-in K8s)    | Enforcer des profils `restricted` sur les namespaces |
| mTLS entre services           | Istio / Linkerd               | Chiffrer le trafic pod-à-pod          |
| Rotation automatique secrets  | Vault + Vault Agent           | Renouveler les credentials sans redéployer |
| Falco                         | Falco (runtime security)      | Détecter les comportements suspects en temps réel |
