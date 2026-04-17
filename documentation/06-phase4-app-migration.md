# Phase 4 — Migration de l'app Laravel vers Kubernetes — Documentation Complète

## Objectif

Prendre une application **docker-compose** classique (app Laravel + MySQL) et la "kubernetiser" : transformer chaque service en ressources K8s (Deployment, Service, PVC, Secret, Ingress).

---

## 1. Comprendre ce qu'on migre

### Docker-compose original (3 services)

```
traefik  → reverse proxy        → remplacé par NGINX Ingress (déjà en place)
app      → Laravel PHP 8.2      → Deployment K8s
db       → MySQL 8.0            → Deployment K8s
```

### Routes exposées par l'app

| Méthode | Endpoint            | Action                          |
|---------|---------------------|---------------------------------|
| GET     | /api/counter/add    | Incrémente le compteur en MySQL |
| GET     | /api/counter/count  | Retourne la valeur courante     |

---

## 2. Concepts clés — docker-compose VS Kubernetes

| docker-compose              | Kubernetes                          | Pourquoi                            |
|-----------------------------|-------------------------------------|-------------------------------------|
| `image: mysql:8.0`          | `Deployment` avec l'image           | K8s gère les pods, pas les conteneurs directement |
| `volumes: mysql_data:/var/lib/mysql` | `PersistentVolumeClaim` + `volumeMount` | K8s abstrait le stockage via les PV |
| `environment: MYSQL_PASSWORD=xxx` | `Secret` + `secretKeyRef`      | Les secrets ne doivent pas être en clair dans les manifests |
| `services.db` (nom DNS)     | `Service` nommé `mysql`             | Le nom du Service devient le hostname DNS interne |
| `ports: 3306:3306`          | Service `ClusterIP` (interne seul)  | MySQL n'a pas besoin d'être exposé à l'extérieur |
| `traefik` (reverse proxy)   | `Ingress` + NGINX Ingress Controller | Standard K8s pour le routing HTTP   |

---

## 3. Build et push de l'image Docker

L'image devait être buildée en **ARM64** (même architecture que nos EC2 t4g.medium).
Docker Desktop n'étant pas disponible sur le Mac, on a buildé directement sur **node-1**.

```bash
# Transfert du code source sur node-1
rsync -avz --exclude='vendor' --exclude='node_modules' \
  sample-app-master/sample-app-master/ ec2-user@node-1:/tmp/sample-app/

# Build + push depuis node-1 (ARM64 natif)
sudo docker build -t mistererson/kubequest-app:latest /tmp/sample-app/
echo 'MOT_DE_PASSE' | sudo docker login -u mistererson --password-stdin
sudo docker push mistererson/kubequest-app:latest
```

**Résultat** : image 717MB ARM64, sha256:`8e0db951...` disponible publiquement sur DockerHub.

---

## 4. Les manifests — explication détaillée

### 00-namespace.yaml

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: app
```

**Pourquoi un Namespace ?**  
Isoler les ressources de l'app des autres namespaces (monitoring, logging...). Le DNS interne est alors `<service>.app.svc.cluster.local`.

---

### 01-mysql-secret.yaml — Secret K8s

Les mots de passe sont encodés en **base64** (≠ chiffrés — c'est juste du formatage).

```bash
echo -n "REDACTED_DB_PASSWORD" | base64   # → <valeur-base64>
```

**Règle d'or** : jamais de mots de passe en clair dans les manifests. Toujours utiliser un `Secret`.

En production on irait plus loin : **AWS Secrets Manager** ou **Vault** + External Secrets Operator.

---

### 02-mysql.yaml — PVC + Deployment + Service

#### PersistentVolumeClaim (PVC)

```yaml
storageClassName: local-path    # local-path-provisioner installé en Phase 3
resources:
  requests:
    storage: 2Gi
```

Le PVC **réclame** du stockage. Le `local-path-provisioner` crée automatiquement un dossier sur le nœud qui héberge le pod MySQL (ex: `/opt/local-path-provisioner/...`).

**Important** : `accessModes: ReadWriteOnce` = montable en écriture sur **un seul nœud**. C'est pourquoi MySQL est limité à **1 réplica** (sinon, 2 pods sur 2 nœuds différents ne pourraient pas accéder au même PVC en écriture simultanément).

#### Deployment MySQL

Points importants :
- `replicas: 1` — base de données = toujours 1 réplica (le clustering MySQL est une autre histoire)
- `--default-authentication-plugin=mysql_native_password` — nécessaire pour la compatibilité Laravel/PDO
- `readinessProbe` avec `mysqladmin ping` — K8s attend que MySQL réponde avant de router du trafic vers le pod
- `env` lus depuis le Secret via `secretKeyRef`

#### Service MySQL (ClusterIP)

```yaml
metadata:
  name: mysql    # ← ce nom devient le hostname DNS
spec:
  type: ClusterIP  # interne uniquement
  ports:
    - port: 3306
```

**Service Discovery K8s** : n'importe quel pod dans le namespace `app` peut atteindre MySQL via le hostname `mysql` (ou `mysql.app.svc.cluster.local`). C'est pour ça que dans le Deployment Laravel on met `DB_HOST: mysql`.

---

### 03-app.yaml — Deployment + Service + Ingress

#### Deployment Laravel

```yaml
replicas: 2    # 2 réplicas = tolérance à la panne + répartition de charge
```

Contrairement à MySQL, une app stateless comme Laravel **peut** avoir plusieurs réplicas — chaque requête HTTP est indépendante.

Variables d'environnement :
- `APP_KEY` — clé de chiffrement Laravel (en prod : mettre dans un Secret)
- `DB_HOST: mysql` — pointe vers le Service K8s nommé "mysql"
- `DB_DATABASE`, `DB_USERNAME`, `DB_PASSWORD` — lus depuis le Secret

#### Ingress

```yaml
ingressClassName: nginx
rules:
  - host: app.kubequest.local
    http:
      paths:
        - path: /
          backend:
            service:
              name: app
              port: 80
```

**Flux d'une requête** :
```
Client → NodePort 30080 → NGINX Ingress Controller
       → vérifie le header "Host: app.kubequest.local"
       → route vers Service "app" port 80
       → distribue entre les 2 pods Laravel
```

---

## 5. Déploiement — commandes et résultats

```bash
# Application des manifests dans l'ordre
kubectl apply -f kubernetes/manifests/app/00-namespace.yaml
kubectl apply -f kubernetes/manifests/app/01-mysql-secret.yaml
kubectl apply -f kubernetes/manifests/app/02-mysql.yaml
kubectl apply -f kubernetes/manifests/app/03-app.yaml
```

Résultat :
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

### Vérification des pods

```bash
kubectl get pods -n app
```

```
NAME                   READY   STATUS    RESTARTS   AGE
app-659b44c55d-4gj5m   1/1     Running   0          2m
app-659b44c55d-clth7   1/1     Running   0          2m
mysql-7c76bb88-gknfc   1/1     Running   0          2m
```

---

## 6. Migrations de base de données

En docker-compose, on aurait utilisé `docker-compose exec app php artisan migrate`. En K8s :

```bash
kubectl exec -n app deployment/app -- php artisan migrate --force
```

```
Migration table created successfully.
Migrated:  2014_10_12_000000_create_users_table
Migrated:  2014_10_12_100000_create_password_resets_table
Migrated:  2019_08_19_000000_create_failed_jobs_table
Migrated:  2019_12_14_000001_create_personal_access_tokens_table
Migrated:  2023_08_21_130800_create_counters_table
```

---

## 7. Test end-to-end

```bash
# Depuis node-1 (le NodePort 30080 est accessible sur tous les nœuds)
curl http://localhost:30080/api/counter/count -H "Host: app.kubequest.local"
# → {"value":0}

curl http://localhost:30080/api/counter/add -H "Host: app.kubequest.local"
# → {"value":"1"}

curl http://localhost:30080/api/counter/add -H "Host: app.kubequest.local"
# → {"value":"2"}

curl http://localhost:30080/api/counter/count -H "Host: app.kubequest.local"
# → {"value":"2"}
```

**L'app est fonctionnelle.** Le compteur persiste en MySQL, servi par 2 pods Laravel derrière un Ingress NGINX.

---

## 8. Architecture finale

```
Internet
   │
   │  port 30080 (NodePort)
   ▼
NGINX Ingress Controller   (namespace: ingress-nginx)
   │
   │  Host: app.kubequest.local → Service app:80
   ▼
Service app (ClusterIP:80)   (namespace: app)
   │
   ├── Pod app-xxx-4gj5m  (Laravel, node-2)
   └── Pod app-xxx-clth7  (Laravel, node-3)
              │
              │  DB_HOST=mysql → Service mysql:3306
              ▼
         Service mysql (ClusterIP:3306)
              │
              └── Pod mysql-xxx-gknfc
                       │
                       └── PVC mysql-pvc (2Gi, local-path, node-4)
```

---

## 9. Différences avec la production

| Lab (notre setup)                    | Production                            |
|---------------------------------------|---------------------------------------|
| `local-path-provisioner` (hostPath)   | EBS/NFS/Ceph — stockage réseau        |
| Secret en base64 dans les manifests   | AWS Secrets Manager + ESO             |
| `imagePullPolicy: Always`             | Image taggée avec le SHA du commit    |
| `php artisan migrate --force` manuel  | Job K8s ou init container             |
| 1 réplica MySQL                       | RDS Multi-AZ ou MySQL Operator        |
| `app.kubequest.local` (DNS local)     | Vrai nom de domaine + cert TLS        |

---

## Résumé

La migration docker-compose → Kubernetes revient à :
1. **Chaque service** → un `Deployment` (ou `StatefulSet` pour les BDD en prod)
2. **Chaque port exposé** → un `Service` (ClusterIP interne, NodePort/LoadBalancer externe)
3. **Chaque volume** → un `PersistentVolumeClaim`
4. **Chaque variable sensible** → un `Secret`
5. **Le reverse proxy** → un `Ingress`
