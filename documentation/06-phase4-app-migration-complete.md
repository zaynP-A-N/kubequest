# Phase 4 — Migration Laravel vers Kubernetes — Documentation Exhaustive

> **Date** : 9 avril 2026  
> **Cluster** : 4 nœuds ARM64 (t4g.medium, eu-central-1), Kubernetes v1.29.15  
> **App** : Laravel PHP 8.2 + Apache + MySQL 8.0  
> **Image Docker** : `mistererson/kubequest-app:latest` (717 MB, ARM64)

---

## Table des matières

1. [L'application source — ce qu'on migre](#1-lapplication-source)
2. [Pourquoi docker-compose ne suffit pas en prod](#2-pourquoi-docker-compose-ne-suffit-pas)
3. [Préparation — Build et push de l'image](#3-préparation--build-et-push-de-limage)
4. [Les manifests Kubernetes — chaque fichier expliqué](#4-les-manifests-kubernetes)
   - [00-namespace.yaml](#00-namespaceyaml)
   - [01-mysql-secret.yaml](#01-mysql-secretyaml)
   - [02-mysql.yaml — PVC + Deployment + Service](#02-mysqlyaml)
   - [03-app.yaml — Deployment + Service + Ingress](#03-appyaml)
5. [Déploiement — toutes les commandes](#5-déploiement--toutes-les-commandes)
6. [Migrations de base de données](#6-migrations-de-base-de-données)
7. [Tests end-to-end](#7-tests-end-to-end)
8. [Architecture finale et flux réseau](#8-architecture-finale-et-flux-réseau)
9. [Commandes de debug quotidiennes](#9-commandes-de-debug-quotidiennes)
10. [Comment ça se fait en entreprise](#10-comment-ça-se-fait-en-entreprise)

---

## 1. L'application source

### Structure docker-compose.yaml original

```yaml
services:
  traefik:         # reverse proxy
  app:             # Laravel PHP 8.2 + Apache
  db:              # MySQL 8.0
```

**3 services → 3 "blocs" à migrer vers K8s.**

Le service `traefik` est **déjà remplacé** par NGINX Ingress Controller installé en Phase 3. On n'a donc que `app` et `db` à migrer.

### L'app Laravel — ce qu'elle fait

L'application expose 2 endpoints HTTP :

| Méthode | Route               | Action                                                  |
|---------|---------------------|---------------------------------------------------------|
| `GET`   | `/api/counter/add`  | Incrémente le compteur de 1 en base MySQL, retourne `{"value": N}` |
| `GET`   | `/api/counter/count`| Retourne la valeur courante du compteur sans modifier   |

Le modèle `Counter` est stocké en MySQL dans la table `counters`. Laravel lit `DB_HOST`, `DB_DATABASE`, `DB_USERNAME`, `DB_PASSWORD` depuis les variables d'environnement pour se connecter.

### Variables d'environnement nécessaires

```
APP_ENV=production
APP_DEBUG=false
APP_KEY=REDACTED_APP_KEY
DB_CONNECTION=mysql
DB_HOST=mysql          ← le nom du Service K8s MySQL
DB_PORT=3306
DB_DATABASE=app_database
DB_USERNAME=app_user
DB_PASSWORD=REDACTED_DB_PASSWORD
```

### Dockerfile en résumé

```dockerfile
FROM php:8.2-apache
# Installe pdo_mysql (driver PHP pour MySQL)
# Installe Composer
# Copie le code dans /var/www/html
# DocumentRoot = /var/www/html/public (dossier public Laravel)
# Expose le port 80
```

---

## 2. Pourquoi docker-compose ne suffit pas

docker-compose est un outil de développement local. Il tourne sur **une seule machine**. Si cette machine tombe, tout tombe.

Kubernetes résout ça :

| Problème docker-compose             | Solution Kubernetes                         |
|-------------------------------------|---------------------------------------------|
| Single point of failure             | Pods répartis sur 4 nœuds                   |
| Redémarrage manuel si crash         | `restartPolicy: Always` automatique         |
| 0 rolling update sans downtime      | `RollingUpdate` strategy                    |
| Volumes liés à la machine locale    | PersistentVolume sur n'importe quel nœud    |
| Mise à l'échelle manuelle           | `kubectl scale` ou HPA automatique          |
| Pas d'exposition HTTP structurée    | Ingress avec routing par Host/Path          |
| Secrets en clair dans .env          | Secret K8s (ou Vault en prod)               |

---

## 3. Préparation — Build et push de l'image

### Pourquoi builder sur node-1 et non sur le Mac

Nos EC2 sont des **t4g.medium** — architecture **ARM64** (processeur Graviton2 d'AWS). Le Mac est aussi ARM64 (Apple Silicon), mais Docker Desktop n'était pas lancé. On a donc utilisé Docker installé sur node-1 pour builder nativement en ARM64.

> **Règle** : une image doit être buildée pour la même architecture que les nœuds qui vont exécuter les pods. Si on avait buildé en AMD64, Kubernetes aurait refusé de démarrer les pods avec une erreur `exec format error`.

### Étape 1 — Transférer le code source sur node-1

```bash
rsync -avz \
  --exclude='vendor' \
  --exclude='node_modules' \
  sample-app-master/sample-app-master/ \
  ec2-user@node-1:/tmp/sample-app/
```

**Explication de chaque option :**

| Option              | Rôle                                                              |
|---------------------|-------------------------------------------------------------------|
| `-a`                | Archive : préserve permissions, dates, liens symboliques          |
| `-v`                | Verbose : affiche les fichiers transférés                         |
| `-z`                | Compresse les données pendant le transfert (réduit la bande passante) |
| `--exclude='vendor'`| Exclut les dépendances PHP (400 MB, reconstruites par Composer dans le Dockerfile) |
| `--exclude='node_modules'` | Exclut les dépendances Node.js inutiles pour la prod       |

**Pourquoi rsync et pas scp ?**  
`rsync` est incrémental — si on retransfère, seuls les fichiers modifiés sont envoyés. `scp` retransfère tout. En entreprise on utilise des **pipelines CI/CD** qui font ça automatiquement à chaque commit.

### Étape 2 — Login DockerHub depuis node-1

```bash
echo 'MOT_DE_PASSE_DOCKERHUB' | sudo docker login -u mistererson --password-stdin
```

**Pourquoi `--password-stdin` et pas `-p MOT_DE_PASSE` ?**  
Passer un mot de passe directement dans la commande (`-p xxx`) l'expose dans :
- l'historique bash (`~/.bash_history`)
- les logs système (`/var/log/auth.log`)
- la sortie de `ps aux` pendant l'exécution

`--password-stdin` lit le mot de passe depuis stdin, ce qui ne laisse aucune trace. C'est une **bonne pratique de sécurité OWASP A02 (Cryptographic Failures)**.

### Étape 3 — Build de l'image

```bash
sudo docker build -t mistererson/kubequest-app:latest /tmp/sample-app/
```

**Explication :**

| Partie                          | Rôle                                                                 |
|---------------------------------|----------------------------------------------------------------------|
| `docker build`                  | Lit le Dockerfile et crée une image                                  |
| `-t mistererson/kubequest-app`  | Tag (nom) de l'image : `<dockerhub-user>/<nom-image>`                |
| `:latest`                       | Version/tag de l'image (en prod on utilise le SHA du commit Git)     |
| `/tmp/sample-app/`              | Contexte de build : dossier contenant le Dockerfile et le code       |

**Résultat** : image de 717 MB buildée en ARM64 nativement sur node-1.

> **En entreprise** : le build est fait par un runner CI/CD (GitLab CI, GitHub Actions, Jenkins) dans un conteneur Docker-in-Docker ou via BuildKit. L'image est taguée avec le SHA du commit (`git rev-parse --short HEAD`) pour une traçabilité parfaite. Le mot de passe DockerHub est dans les **secrets CI/CD**, jamais dans le code.

### Étape 4 — Push de l'image sur DockerHub

```bash
sudo docker push mistererson/kubequest-app:latest
```

Cette commande envoie les layers de l'image sur DockerHub. Docker utilise un système de layers : si une couche de base (ex: `php:8.2-apache`) est déjà sur le registry, elle n'est pas renvoyée.

**Résultat** : `sha256:8e0db951f62b50f27d456fd7efcb5703d9c7b70e88f48b82ebd4e451c85d9865`

> **En entreprise** : on utilise un **registry privé** (AWS ECR, GitLab Registry, Harbor) pour ne pas exposer les images publiquement. DockerHub en mode public est acceptable pour un lab.

---

## 4. Les manifests Kubernetes

Un **manifest** est un fichier YAML qui décrit l'état désiré d'une ressource K8s. On dit "désiré" car Kubernetes est **déclaratif** : on décrit CE QU'ON VEUT, pas comment y arriver. Le cluster reconcilie l'état actuel vers l'état désiré en permanence.

### Architecture de nos manifests

```
kubernetes/manifests/app/
├── 00-namespace.yaml          # Isolation de l'app
├── 01-mysql-secret.yaml       # Mots de passe MySQL
├── 02-mysql.yaml              # Stockage + base de données
└── 03-app.yaml                # Application + exposition HTTP
```

Les fichiers sont préfixés par des numéros car `kubectl apply` peut les lire dans l'ordre alphabétique, et le namespace doit exister AVANT les autres ressources.

---

### 00-namespace.yaml

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: app
  labels:
    app.kubernetes.io/managed-by: kubectl
```

**Qu'est-ce qu'un Namespace ?**

Un namespace est un **espace de noms logique** dans le cluster. Il permet d'isoler des ressources. Par défaut Kubernetes a :
- `default` — pour les ressources sans namespace spécifié
- `kube-system` — pour les composants internes (DNS, proxy, etc.)
- `kube-public` — accessible publiquement
- `ingress-nginx` — notre Ingress Controller (créé en Phase 3)
- `monitoring` — Prometheus/Grafana (créé en Phase 3)

On crée `app` pour isoler nos ressources de l'application.

**Avantages concrets :**
1. **DNS** : les services sont accessibles via `<service>.<namespace>.svc.cluster.local`. Un pod dans le namespace `app` peut atteindre MySQL via `mysql` (court) ou `mysql.app.svc.cluster.local` (complet). Un pod dans un autre namespace doit utiliser le nom complet.
2. **RBAC** : on peut restreindre qui a le droit de voir/modifier les ressources de ce namespace
3. **Quotas** : on peut limiter la RAM/CPU consommée par ce namespace
4. **`kubectl get pods -n app`** : on ne voit que les pods de notre app, pas le bruit du cluster

> **En entreprise** : chaque équipe/application a son namespace. Les namespaces sont créés par l'équipe plateforme avec des quotas précis. L'équipe dev a des droits limités (pas de `kubectl delete namespace`).

**Le label `app.kubernetes.io/managed-by: kubectl`** est une convention de labeling recommandée par Kubernetes. En entreprise ce serait `managed-by: helm` ou `managed-by: argocd`.

---

### 01-mysql-secret.yaml

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: mysql-secret
  namespace: app
type: Opaque
data:
  mysql-database: <base64-app_database>        # app_database
  mysql-user: <base64-app_user>                # app_user
  mysql-password: <base64-REDACTED_DB_PASSWORD>        # REDACTED_DB_PASSWORD
  mysql-root-password: <base64-REDACTED_DB_ROOT_PASSWORD>  # REDACTED_DB_ROOT_PASSWORD
```

**Qu'est-ce qu'un Secret K8s ?**

Un Secret est une ressource K8s conçue pour stocker des données sensibles (mots de passe, tokens, certificats). Les valeurs sont encodées en **base64**.

**IMPORTANT — base64 ≠ chiffrement**

```bash
# Encoder une valeur
echo -n "REDACTED_DB_PASSWORD" | base64
# → <valeur-base64-du-password>

# Décoder une valeur (n'importe qui peut le faire)
echo "<valeur-base64-du-password>" | base64 --decode
# → REDACTED_DB_PASSWORD
```

Le base64 est juste un format de sérialisation. Un Secret K8s est plus sécurisé qu'une ConfigMap pour plusieurs raisons :
- Kubernetes peut stocker les Secrets chiffrés dans etcd (avec `EncryptionConfiguration`)
- RBAC peut autoriser l'accès aux ConfigMaps mais pas aux Secrets
- Des outils comme `kubeseal` ou Vault peuvent gérer les Secrets de manière vraiment sécurisée

**`type: Opaque`** signifie "données arbitraires". D'autres types existent : `kubernetes.io/tls` pour les certificats, `kubernetes.io/dockerconfigjson` pour les credentials de registry, etc.

**Comment les valeurs sont injectées dans les pods :**

Dans `02-mysql.yaml` et `03-app.yaml`, on référence le Secret ainsi :
```yaml
env:
  - name: MYSQL_PASSWORD
    valueFrom:
      secretKeyRef:
        name: mysql-secret   # nom du Secret
        key: mysql-password  # clé dans le Secret
```

Kubernetes injecte la valeur décodée (pas base64, la valeur réelle) dans la variable d'environnement du conteneur.

> **En entreprise** : les Secrets K8s en base64 dans Git c'est une mauvaise pratique. On utilise :
> - **Sealed Secrets** (Bitnami) : chiffre les secrets avec une clé asymétrique, seul le cluster peut déchiffrer
> - **External Secrets Operator** : synchronise depuis AWS Secrets Manager / HashiCorp Vault
> - **SOPS** : chiffre le fichier YAML avec GPG ou AWS KMS avant de le committer

---

### 02-mysql.yaml

Ce fichier contient 3 ressources K8s séparées par `---`.

#### Ressource 1 — PersistentVolumeClaim (PVC)

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: mysql-pvc
  namespace: app
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: local-path
  resources:
    requests:
      storage: 2Gi
```

**Qu'est-ce qu'un PVC ?**

En docker-compose, les volumes sont des dossiers locaux sur ta machine. Dans Kubernetes, le stockage est abstrait en 3 couches :

```
PersistentVolumeClaim (PVC)  ←── ce que le pod demande
         ↓ (binding)
PersistentVolume (PV)        ←── la ressource de stockage réelle
         ↓
StorageClass                 ←── le "fournisseur" de stockage (local-path-provisioner ici)
```

**Le PVC** est une **réclamation** de stockage. Le pod dit "j'ai besoin de 2 Gi en lecture/écriture". Le `local-path-provisioner` (installé en Phase 3 via Terraform) répond à cette demande en créant automatiquement un dossier sur le nœud qui héberge le pod MySQL.

**`accessModes: ReadWriteOnce`** signifie que ce volume peut être monté en écriture par **un seul nœud à la fois**. C'est pour ça que MySQL a `replicas: 1` — si on mettait 2 réplicas sur 2 nœuds différents, le deuxième pod ne pourrait pas monter le volume.

Les 3 modes d'accès :
| Mode              | Sigle | Signification                              |
|-------------------|-------|--------------------------------------------|
| ReadWriteOnce     | RWO   | Lecture+écriture depuis 1 seul nœud        |
| ReadOnlyMany      | ROX   | Lecture seule depuis plusieurs nœuds       |
| ReadWriteMany     | RWX   | Lecture+écriture depuis plusieurs nœuds (NFS, Ceph...) |

**`storageClassName: local-path`** désigne la StorageClass utilisée. `local-path` vient du `local-path-provisioner` de Rancher que nous avons installé. Il crée les données dans `/opt/local-path-provisioner/` sur le nœud.

> **En entreprise** : on n'utilise pas `local-path` pour des bases de données en prod. Si le nœud qui héberge MySQL tombe, les données sont perdues. On utilise :
> - **AWS EBS** (via aws-ebs-csi-driver) : disque réseau qui se réattache automatiquement sur un autre nœud
> - **AWS EFS** (NFS managé) : supporte RWX
> - **Ceph/Rook** : stockage distribué auto-hébergé
> - **Amazon RDS** : hors K8s, une base de données managée (le choix le plus raisonnable en prod)

---

#### Ressource 2 — Deployment MySQL

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mysql
  namespace: app
  labels:
    app: mysql
spec:
  replicas: 1
  selector:
    matchLabels:
      app: mysql
  template:
    metadata:
      labels:
        app: mysql
    spec:
      containers:
        - name: mysql
          image: mysql:8.0
          args:
            - "--default-authentication-plugin=mysql_native_password"
          ports:
            - containerPort: 3306
          env:
            - name: MYSQL_DATABASE
              valueFrom:
                secretKeyRef:
                  name: mysql-secret
                  key: mysql-database
            # ... (même pattern pour user, password, root-password)
          volumeMounts:
            - name: mysql-storage
              mountPath: /var/lib/mysql
          readinessProbe:
            exec:
              command: ["mysqladmin", "ping", "-h", "localhost"]
            initialDelaySeconds: 20
            periodSeconds: 5
            failureThreshold: 10
          resources:
            requests:
              memory: "256Mi"
              cpu: "250m"
            limits:
              memory: "512Mi"
      volumes:
        - name: mysql-storage
          persistentVolumeClaim:
            claimName: mysql-pvc
```

**Qu'est-ce qu'un Deployment ?**

Un Deployment est la ressource la plus utilisée en Kubernetes. Il gère le cycle de vie des pods :
- Il crée et maintient le nombre de réplicas désiré
- Si un pod crashe, il en recrée un automatiquement
- Il gère les mises à jour (rolling update) sans downtime
- Il permet le rollback à une version précédente

**Le lien Deployment → Pods via les labels :**

```
Deployment (spec.selector.matchLabels: app=mysql)
    ├── cherche les pods avec label "app=mysql"
    └── crée des pods avec label "app=mysql" (spec.template.metadata.labels)
```

C'est le mécanisme fondamental de K8s : les resources se trouvent via des **labels** (étiquettes), pas par nom direct.

**`args: ["--default-authentication-plugin=mysql_native_password"]`**

MySQL 8.0 utilise par défaut l'authentification `caching_sha2_password`. Le driver PDO de PHP (utilisé par Laravel) ne supporte pas ce plugin dans certaines versions. On force `mysql_native_password` pour la compatibilité. En production on mettrait à jour le driver PHP plutôt que dégrader la sécurité de MySQL.

**La `readinessProbe`** :

```yaml
readinessProbe:
  exec:
    command: ["mysqladmin", "ping", "-h", "localhost"]
  initialDelaySeconds: 20   # attend 20s avant le premier check (MySQL met du temps à démarrer)
  periodSeconds: 5          # vérifie toutes les 5s
  failureThreshold: 10      # 10 échecs consécutifs = pod NotReady
```

Une probe de type `exec` exécute une commande DANS le conteneur. Si la commande retourne 0 = OK, si elle retourne autre chose = échec.

**Pourquoi une readinessProbe ?**  
Sans elle, K8s enverrait du trafic vers MySQL dès que le conteneur démarre, avant qu'il soit prêt à accepter des connexions. Le pod Laravel essaierait de se connecter et échouerait. La readinessProbe empêche cela : tant que `mysqladmin ping` échoue, le pod est marqué `NotReady` et ne reçoit pas de trafic.

**La différence entre `readinessProbe` et `livenessProbe` :**

| Probe            | Quand elle échoue                            | Action K8s                     |
|------------------|----------------------------------------------|--------------------------------|
| `readinessProbe` | Le pod n'est pas encore prêt à servir        | Retire le pod du Service (no traffic) |
| `livenessProbe`  | Le pod est bloqué/crashé et doit être relancé| Redémarre le conteneur         |
| `startupProbe`   | L'app met longtemps à démarrer               | Désactive les 2 autres pendant le démarrage |

**`resources` — requests et limits :**

```yaml
resources:
  requests:
    memory: "256Mi"
    cpu: "250m"    # 250 millicores = 0.25 vCPU
  limits:
    memory: "512Mi"
    # pas de limit CPU → MySQL peut utiliser tout le CPU disponible
```

- **requests** : ce que le scheduler K8s réserve sur le nœud pour planifier le pod. Un nœud avec 2 Gi de RAM libre peut accueillir 8 pods avec `memory requests: 256Mi`.
- **limits** : le maximum absolu. Si le pod dépasse `memory limits`, il est tué (OOMKilled). Si il dépasse `cpu limits`, il est throttlé (ralenti).

**`volumeMounts` + `volumes` :**

```yaml
# Dans le conteneur : où monter le volume
volumeMounts:
  - name: mysql-storage       # référence le volume défini plus bas
    mountPath: /var/lib/mysql  # dossier dans le conteneur

# Au niveau du pod : quelle source de données
volumes:
  - name: mysql-storage
    persistentVolumeClaim:
      claimName: mysql-pvc    # pointe sur notre PVC
```

`/var/lib/mysql` est le dossier où MySQL stocke ses fichiers de base de données. En le montant sur le PVC, les données survivent aux redémarrages du pod.

---

#### Ressource 3 — Service MySQL

```yaml
apiVersion: v1
kind: Service
metadata:
  name: mysql
  namespace: app
spec:
  selector:
    app: mysql
  ports:
    - port: 3306
      targetPort: 3306
  type: ClusterIP
```

**Qu'est-ce qu'un Service ?**

Un Service est un point d'accès stable vers un ou plusieurs pods. Les pods sont éphémères — ils peuvent être supprimés et recréés à tout moment avec de nouvelles IPs. Le Service a une IP fixe (ClusterIP) et un nom DNS stable.

**`type: ClusterIP`** est le type par défaut. Il expose le Service uniquement à l'intérieur du cluster. Personne depuis l'extérieur ne peut atteindre MySQL directement — c'est voulu pour la sécurité (principe du moindre privilège).

**Le Service Discovery K8s :**

Quand on crée un Service nommé `mysql` dans le namespace `app`, CoreDNS (le serveur DNS interne de K8s) crée automatiquement un enregistrement DNS :

```
mysql                              → 10.96.x.x (ClusterIP)
mysql.app                          → 10.96.x.x
mysql.app.svc                      → 10.96.x.x
mysql.app.svc.cluster.local        → 10.96.x.x
```

C'est pour ça que dans `03-app.yaml` on met `DB_HOST: mysql` — Laravel résout `mysql` en l'IP ClusterIP du Service, qui load-balance vers le pod MySQL.

**Comment le Service trouve les pods : le selector**

```yaml
selector:
  app: mysql   # ← sélectionne tous les pods avec le label app=mysql
```

Le Service maintient en permanence une liste des pods éligibles (les **Endpoints**). Si un pod MySQL est tué et recréé avec une nouvelle IP, le Service met à jour ses Endpoints automatiquement.

```bash
# Pour voir les endpoints d'un service
kubectl get endpoints -n app mysql
# NAME    ENDPOINTS              AGE
# mysql   192.168.236.134:3306   5m
```

---

### 03-app.yaml

Ce fichier contient 3 ressources : Deployment Laravel, Service app, Ingress.

#### Ressource 1 — Deployment Laravel

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: app
  namespace: app
spec:
  replicas: 2
  selector:
    matchLabels:
      app: laravel
  template:
    spec:
      containers:
        - name: app
          image: mistererson/kubequest-app:latest
          imagePullPolicy: Always
          ports:
            - containerPort: 80
          env:
            - name: APP_ENV
              value: "production"
            - name: APP_DEBUG
              value: "false"
            - name: APP_KEY
              value: "REDACTED_APP_KEY"
            - name: DB_CONNECTION
              value: "mysql"
            - name: DB_HOST
              value: "mysql"          # nom du Service MySQL
            - name: DB_PORT
              value: "3306"
            - name: DB_DATABASE
              valueFrom:
                secretKeyRef:
                  name: mysql-secret
                  key: mysql-database
            - name: DB_USERNAME
              valueFrom:
                secretKeyRef:
                  name: mysql-secret
                  key: mysql-user
            - name: DB_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: mysql-secret
                  key: mysql-password
          readinessProbe:
            httpGet:
              path: /api/counter/count
              port: 80
            initialDelaySeconds: 15
            periodSeconds: 10
            failureThreshold: 5
          resources:
            requests:
              memory: "128Mi"
              cpu: "100m"
            limits:
              memory: "512Mi"
```

**`replicas: 2`** — Pourquoi 2 et pas 1 ?

Laravel est une application **stateless** : chaque requête HTTP est indépendante, aucune information n'est stockée dans la mémoire du process entre deux requêtes (les sessions sont en base/fichiers, pas en RAM). On peut donc avoir plusieurs réplicas sans problème de cohérence.

2 réplicas signifie :
- Si un des 2 pods crashe → l'autre continue à servir
- Les requêtes sont distribuées entre les 2 pods par le Service
- On peut mettre à jour l'image sans downtime (rolling update : K8s crée le nouveau pod, attend qu'il soit Ready, puis supprime l'ancien)

**`imagePullPolicy: Always`** — À chaque démarrage de pod, K8s vérifie sur DockerHub si l'image a changé. En production avec un tag fixe (ex: `v1.2.3`) on utilise `IfNotPresent` pour économiser de la bande passante.

**La `readinessProbe` httpGet :**

```yaml
readinessProbe:
  httpGet:
    path: /api/counter/count  # K8s fait une requête GET HTTP vers ce chemin
    port: 80
  initialDelaySeconds: 15     # attend 15s (Apache + Laravel mettent quelques secondes à démarrer)
  periodSeconds: 10           # vérifie toutes les 10s
  failureThreshold: 5         # 5 échecs = NotReady
```

K8s fait une requête `GET http://pod-ip:80/api/counter/count` depuis l'intérieur du cluster. Si la réponse est HTTP 2xx ou 3xx = OK. Ici on utilise `/api/counter/count` car c'est un endpoint simple qui teste à la fois Apache, PHP, Laravel ET la connexion MySQL (il lit en base).

**`DB_HOST: mysql`** — Pourquoi "mysql" ?

Le nom `mysql` correspond exactement au `metadata.name` du Service défini dans `02-mysql.yaml`. CoreDNS résout ce nom en l'IP ClusterIP du Service MySQL. C'est le **Service Discovery** de Kubernetes.

---

#### Ressource 2 — Service app

```yaml
apiVersion: v1
kind: Service
metadata:
  name: app
  namespace: app
spec:
  selector:
    app: laravel
  ports:
    - port: 80
      targetPort: 80
  # type: ClusterIP (par défaut)
```

Service interne qui load-balance entre les 2 pods Laravel. L'Ingress pointe sur ce Service pour router le trafic entrant.

---

#### Ressource 3 — Ingress

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: app-ingress
  namespace: app
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
spec:
  ingressClassName: nginx
  rules:
    - host: app.kubequest.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: app
                port:
                  number: 80
```

**Qu'est-ce qu'un Ingress ?**

L'Ingress est la ressource K8s qui gère l'accès HTTP/HTTPS depuis l'extérieur. C'est comme un fichier de configuration de reverse proxy (nginx.conf, Apache VirtualHost), mais en YAML Kubernetes.

**L'Ingress seul ne fait rien.** Il faut un **Ingress Controller** qui lit les ressources Ingress et configure le vrai reverse proxy. On a NGINX Ingress Controller installé en Phase 3.

```
Ingress (ressource K8s)     ←── déclaration de règles de routing
     ↓ (lue par)
Ingress Controller (pod)    ←── traduit en config nginx.conf dynamiquement
     ↓ (configure)
NGINX (dans le pod)         ←── le vrai reverse proxy qui route le trafic
```

**`ingressClassName: nginx`** indique quel Ingress Controller utiliser (on pourrait avoir plusieurs : nginx, traefik, haproxy...).

**`host: app.kubequest.local`** — NGINX ne forward le trafic que si le header HTTP `Host` vaut `app.kubequest.local`. Sinon il retourne 404.

**`pathType: Prefix`** — toutes les URLs commençant par `/` sont routées vers ce backend.

**L'annotation `nginx.ingress.kubernetes.io/rewrite-target: /`** — réécrit l'URL avant de la transmettre au Service. Ici c'est transparent (/ → /), mais utile si on voulait exposer l'app sous `/myapp/` mais que l'app s'attend à recevoir des requêtes à `/`.

**Flux complet d'une requête :**

```
Utilisateur (Mac/Browser)
    │ curl http://3.74.128.83:30080/api/counter/add
    │ Header: Host: app.kubequest.local
    ▼
NodePort 30080 (ouvert sur TOUS les nœuds par K8s)
    │ redirige vers le pod NGINX Ingress Controller
    ▼
NGINX Ingress Controller (pod dans ingress-nginx)
    │ vérifie: Host=app.kubequest.local, path=/api/counter/add → règle Ingress trouvée
    │ forward vers Service "app" port 80
    ▼
Service app (ClusterIP, load-balance)
    │ distribue vers l'un des 2 pods Laravel
    ▼
Pod Laravel app-xxx-4gj5m (ou app-xxx-clth7)
    │ Apache reçoit la requête, PHP exécute Laravel
    │ Laravel appelle Service MySQL via DNS "mysql"
    ▼
Service mysql (ClusterIP:3306)
    ▼
Pod MySQL
    │ execute la requête SQL
    ▼
Réponse JSON {"value":"3"} remonte la chaîne en sens inverse
```

---

## 5. Déploiement — toutes les commandes

### Application des manifests

```bash
kubectl apply -f kubernetes/manifests/app/00-namespace.yaml
kubectl apply -f kubernetes/manifests/app/01-mysql-secret.yaml
kubectl apply -f kubernetes/manifests/app/02-mysql.yaml
kubectl apply -f kubernetes/manifests/app/03-app.yaml
```

**Pourquoi `kubectl apply` et pas `kubectl create` ?**

| Commande         | Comportement                                                      |
|------------------|-------------------------------------------------------------------|
| `kubectl create` | Crée la ressource. Échoue si elle existe déjà.                    |
| `kubectl apply`  | Crée si inexistant, met à jour si déjà existant. **Idempotent.**  |
| `kubectl replace`| Remplace entièrement. Détruit et recrée.                          |

`apply` est **idempotent** : on peut lancer la commande 10 fois, le résultat est toujours le même. C'est ce qu'on veut pour de l'infrastructure-as-code.

**Sortie de la commande :**

```
namespace/app created
secret/mysql-secret created
persistentvolumeclaim/mysql-pvc created
deployment.apps/mysql created
service/mysql created
deployment.apps/app created
service/app created
ingress.networking.k8s.io/app-ingress created
```

Chaque ligne confirme la création d'une ressource.

---

## 6. Migrations de base de données

```bash
kubectl exec -n app deployment/app -- php artisan migrate --force
```

**Décryptage de la commande :**

| Partie                      | Rôle                                                                      |
|-----------------------------|---------------------------------------------------------------------------|
| `kubectl exec`              | Exécute une commande dans un conteneur qui tourne                         |
| `-n app`                    | Dans le namespace `app`                                                   |
| `deployment/app`            | Cible un pod du Deployment "app" (K8s choisit lequel)                     |
| `--`                        | Séparateur : tout ce qui suit est la commande à exécuter dans le conteneur|
| `php artisan migrate`       | Commande Laravel pour créer les tables en base de données                 |
| `--force`                   | Nécessaire en `APP_ENV=production` (sinon Laravel demande confirmation)   |

**Résultat :**

```
Migration table created successfully.
Migrated:  2014_10_12_000000_create_users_table (48ms)
Migrated:  2014_10_12_100000_create_password_resets_table (45ms)
Migrated:  2019_08_19_000000_create_failed_jobs_table (52ms)
Migrated:  2019_12_14_000001_create_personal_access_tokens_table (79ms)
Migrated:  2023_08_21_130800_create_counters_table (32ms)
```

`php artisan migrate` :
1. Se connecte à MySQL via les variables d'env (DB_HOST=mysql, etc.)
2. Crée la table `migrations` si elle n'existe pas (pour tracker quelles migrations ont été jouées)
3. Exécute chaque fichier de migration dans `database/migrations/` qui n'a pas encore été joué
4. Crée les tables : `users`, `password_resets`, `failed_jobs`, `personal_access_tokens`, `counters`

> **En entreprise** : on ne fait jamais `kubectl exec ... migrate` manuellement. Les migrations sont lancées par un **init container** (qui tourne avant les pods app) ou par un **Job K8s** déclenché par le pipeline CI/CD avant le déploiement.

---

## 7. Tests end-to-end

```bash
# Test depuis node-1 (le NodePort est accessible sur tous les nœuds)
ssh node-1 curl -s http://localhost:30080/api/counter/count -H Host:app.kubequest.local
# → {"value":0}

ssh node-1 curl -s http://localhost:30080/api/counter/add -H Host:app.kubequest.local
# → {"value":"1"}

ssh node-1 curl -s http://localhost:30080/api/counter/add -H Host:app.kubequest.local
# → {"value":"2"}

ssh node-1 curl -s http://localhost:30080/api/counter/count -H Host:app.kubequest.local
# → {"value":"2"}
```

**Pourquoi on passe par node-1 et pas directement depuis le Mac ?**

Le NodePort 30080 est ouvert sur les nœuds EC2, mais les nœuds workers (node-2/3/4) ont des IPs dynamiques et ne sont accessibles que via le réseau privé AWS. node-1 a une Elastic IP (3.74.128.83) et est notre bastion SSH.

Depuis le Mac on peut aussi utiliser le tunnel SSH :
```bash
# Créer un tunnel local vers le NodePort
ssh -L 30080:localhost:30080 node-1 -N -f
# Puis accéder depuis le Mac
curl -s http://localhost:30080/api/counter/count -H "Host: app.kubequest.local"
```

**Décryptage de l'option `-H Host:app.kubequest.local` :**

`-H` ajoute un header HTTP à la requête. NGINX Ingress ne route que si le header `Host` correspond à une règle Ingress. Sans ce header, NGINX retourne 404 (pas de règle de default backend configurée).

En prod avec un vrai nom de domaine (ex: `app.monentreprise.com`), le header Host est envoyé automatiquement par le navigateur et le DNS résout vers l'IP du cluster. On n'a pas besoin de `-H`.

---

## 8. Architecture finale et flux réseau

```
┌─────────────────────────────────────────────────────────────────────┐
│  Internet                                                            │
└─────────────────────────────┬───────────────────────────────────────┘
                              │ curl http://3.74.128.83:30080
                              │ Header: Host: app.kubequest.local
                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│  node-1 (3.74.128.83 — Elastic IP)                                  │
│  NodePort 30080 → redirige vers NGINX Ingress Controller             │
└─────────────────────────────┬───────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│  namespace: ingress-nginx                                            │
│  Pod: nginx-ingress-controller                                       │
│  → lit les règles Ingress                                            │
│  → Host: app.kubequest.local → Service app:80 (namespace: app)       │
└─────────────────────────────┬───────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│  namespace: app                                                      │
│                                                                      │
│  Service app (ClusterIP:80)                                          │
│  ├── Pod app-xxx-4gj5m  (Laravel, node-2)  172.16.x.x              │
│  └── Pod app-xxx-clth7  (Laravel, node-3)  172.16.x.x              │
│               │                                                      │
│               │ DB_HOST=mysql → DNS → Service mysql:3306             │
│               ▼                                                      │
│  Service mysql (ClusterIP:3306)                                      │
│  └── Pod mysql-xxx-gknfc  (MySQL 8.0, node-4)                       │
│               │                                                      │
│               └── PVC mysql-pvc (2Gi)                               │
│                   → /opt/local-path-provisioner/ sur node-4          │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 9. Commandes de debug quotidiennes

### Voir l'état des pods

```bash
kubectl get pods -n app
```
Colonnes importantes :
- `READY` : `1/1` = le conteneur est prêt (readinessProbe OK). `0/1` = en cours de démarrage ou pas prêt
- `STATUS` : `Running`, `Pending` (pas encore schedulé), `CrashLoopBackOff` (crash en boucle), `OOMKilled` (tué pour dépassement mémoire)
- `RESTARTS` : nombre de fois que le conteneur a été redémarré. Si > 0, quelque chose a crashé

### Voir les logs d'un pod

```bash
kubectl logs -n app deployment/app
kubectl logs -n app deployment/app --previous   # logs du run précédent (utile si crashé)
kubectl logs -n app deployment/app -f           # follow (comme tail -f)
kubectl logs -n app deployment/mysql
```

### Décrire une ressource (debugging avancé)

```bash
kubectl describe pod -n app <nom-du-pod>
kubectl describe deployment -n app app
kubectl describe pvc -n app mysql-pvc
```

`kubectl describe` affiche les **Events** de la ressource — c'est la première chose à regarder quand quelque chose ne marche pas. Les events montrent pourquoi un pod ne démarre pas (image introuvable, PVC non bindé, etc.)

### Voir les ressources allouées

```bash
kubectl get pods -n app -o wide          # + IP du pod et nœud d'hébergement
kubectl top pods -n app                  # consommation CPU/RAM en temps réel (nécessite metrics-server)
kubectl get events -n app --sort-by=.lastTimestamp  # tous les events, triés par date
```

### Accéder au shell d'un pod

```bash
# Shell interactif dans le pod app
kubectl exec -it -n app deployment/app -- /bin/bash

# Shell dans le pod MySQL
kubectl exec -it -n app deployment/mysql -- mysql -u app_user -pREDACTED_DB_PASSWORD app_database
```

### Port-forward — accéder à un service depuis le Mac sans Ingress

```bash
# Forwarde le port 8080 du Mac vers le port 80 du Service app
kubectl port-forward -n app service/app 8080:80
# → curl http://localhost:8080/api/counter/count
```

Utile pour le debug sans passer par l'Ingress.

### Voir l'Ingress et ses règles

```bash
kubectl get ingress -n app
kubectl describe ingress -n app app-ingress
```

### Rollback d'un Deployment

```bash
kubectl rollout history deployment/app -n app      # historique des versions
kubectl rollout undo deployment/app -n app          # retour à la version précédente
kubectl rollout status deployment/app -n app        # état du rollout en cours
```

### Scaler un Deployment

```bash
kubectl scale deployment app -n app --replicas=3   # passe à 3 réplicas
```

---

## 10. Comment ça se fait en entreprise

### Ce qu'on a fait (lab) vs ce qui se fait en prod

#### 1. Build d'image — CI/CD Pipeline

**Lab :** build manuel sur node-1 via SSH.

**Entreprise :**
```
Développeur → git push → GitLab/GitHub
   ↓
CI/CD Pipeline (GitLab CI / GitHub Actions / Jenkins)
   ├── lint + tests unitaires
   ├── docker build -t registry.company.com/app:$CI_COMMIT_SHA .
   ├── docker push registry.company.com/app:$CI_COMMIT_SHA
   └── kubectl set image deployment/app app=registry.company.com/app:$CI_COMMIT_SHA
```

L'image est taguée avec le **SHA du commit Git** pour une traçabilité complète. On sait exactement quel code correspond à quelle image.

---

#### 2. Secrets — External Secrets Operator

**Lab :** `kubectl apply` du Secret avec des valeurs base64 dans Git (à ne jamais faire en prod !).

**Entreprise :**
```yaml
# External Secrets Operator
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: mysql-secret
  namespace: app
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: aws-secrets-manager
    kind: ClusterSecretStore
  target:
    name: mysql-secret          # crée un Secret K8s avec ce nom
  data:
    - secretKey: mysql-password
      remoteRef:
        key: production/myapp/mysql    # chemin dans AWS Secrets Manager
        property: password
```

**AWS Secrets Manager** stocke les secrets chiffrés. External Secrets Operator les synchronise dans K8s. Les secrets ne sont jamais dans Git.

---

#### 3. Stockage — AWS EBS via CSI Driver

**Lab :** `local-path` (données sur le disque local du nœud, perdues si le nœud casse).

**Entreprise avec AWS EKS :**
```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3-encrypted
provisioner: ebs.csi.aws.com      # AWS EBS CSI Driver
parameters:
  type: gp3
  encrypted: "true"
  kmsKeyId: "arn:aws:kms:..."
reclaimPolicy: Retain              # ne pas supprimer le volume si le PVC est supprimé !
volumeBindingMode: WaitForFirstConsumer
```

Un volume EBS est un disque réseau AWS qui se réattache automatiquement si le pod MySQL est replanifié sur un autre nœud. Les données survivent aux défaillances de nœuds.

Mais en réalité en prod, on **n'héberge pas MySQL dans Kubernetes** — on utilise **Amazon RDS** (base de données managée) qui gère automatiquement : backups, Multi-AZ (réplication synchrone sur 2 AZ), mises à jour de sécurité, monitoring.

---

#### 4. Database migrations — Init Container

**Lab :** `kubectl exec ... php artisan migrate --force` lancé manuellement.

**Entreprise :**
```yaml
spec:
  initContainers:
    - name: migrate
      image: mistererson/kubequest-app:$VERSION
      command: ["php", "artisan", "migrate", "--force"]
      env:
        # mêmes variables d'env que l'app
  containers:
    - name: app
      image: mistererson/kubequest-app:$VERSION
      # ...
```

Un **init container** tourne AVANT les conteneurs principaux. Il doit se terminer avec succès (exit 0) avant que K8s démarre le pod app. Si la migration échoue, le pod ne démarre pas et on voit l'erreur dans `kubectl describe`.

---

#### 5. Ingress — TLS + certificat Let's Encrypt

**Lab :** HTTP simple, hostname `.local`, header Host manuel.

**Entreprise :**
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: app-ingress
  annotations:
    cert-manager.io/cluster-issuer: "letsencrypt-prod"    # cert-manager gère le certificat
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - app.monentreprise.com
      secretName: app-tls-cert    # cert-manager crée automatiquement ce Secret
  rules:
    - host: app.monentreprise.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: app
                port:
                  number: 80
```

**cert-manager** renouvelle automatiquement les certificats TLS via Let's Encrypt (ou une CA interne). Zéro intervention manuelle.

---

#### 6. GitOps — ArgoCD

**Lab :** `kubectl apply -f` lancé à la main.

**Entreprise :**

ArgoCD est un opérateur K8s qui surveille un dépôt Git et applique automatiquement les manifests dès qu'ils changent.

```
Développeur → git push manifests/ → GitLab
                    ↓
              ArgoCD (surveille le repo)
                    ↓
              kubectl apply automatique
                    ↓
              Notification Slack : "App v1.2.3 déployée ✅"
```

**Le principe GitOps :** le dépôt Git est la **source de vérité** de l'état du cluster. On ne fait jamais de `kubectl apply` à la main en prod. Tout passe par Git (PR → review → merge → déploiement automatique).

---

#### 7. Observabilité — ce qu'on a déjà

Notre Phase 3 a déjà installé la stack d'observabilité :

| Outil       | Rôle                                                        |
|-------------|-------------------------------------------------------------|
| Prometheus  | Collecte les métriques (CPU, RAM, requêtes/s, latences...)  |
| Grafana     | Dashboards visuels sur les métriques Prometheus             |
| Loki        | Agrège les logs de tous les pods                            |
| Promtail    | Agent DaemonSet qui envoie les logs à Loki                  |

En entreprise on y ajoute des alertes Prometheus (AlertManager) qui envoient des notifications Slack/PagerDuty quand une métrique dépasse un seuil (ex: `pod restarts > 5 en 10 minutes`).

---

### Résumé des outils entreprise à connaître

| Catégorie         | Lab (notre setup)         | Entreprise                              |
|-------------------|---------------------------|-----------------------------------------|
| Build image       | docker build manuel       | GitLab CI / GitHub Actions (pipeline)   |
| Registry          | DockerHub public          | ECR / GitLab Registry / Harbor (privé)  |
| Secrets           | Secret K8s base64         | External Secrets + AWS Secrets Manager  |
| Stockage BDD      | local-path                | EBS CSI Driver ou Amazon RDS            |
| Migrations SQL    | kubectl exec manuel       | Init Container dans le Deployment       |
| Déploiement       | kubectl apply manuel      | ArgoCD (GitOps)                         |
| TLS               | HTTP sans certificat      | cert-manager + Let's Encrypt            |
| Monitoring        | Prometheus + Grafana ✅   | Prometheus + Grafana + AlertManager     |
| Logs              | Loki + Promtail ✅        | Loki / Elasticsearch / Datadog          |
| Ingress           | NGINX Ingress ✅          | NGINX / Traefik / AWS ALB               |
