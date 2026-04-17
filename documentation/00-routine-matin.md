# Routine du matin — KubeQuest Group-53

> À faire chaque fois que les EC2 ont été redémarrés.

---

## Étape 1 — Trouver les nouvelles IPs

Console AWS → EC2 → Instances → filtrer "group-53"

| Nœud   | IP                | Note                      |
|--------|-------------------|---------------------------|
| node-1 | `3.74.128.83`     | Elastic IP — **toujours fixe** |
| node-2 | dynamique         | À noter depuis la console |
| node-3 | dynamique         | À noter depuis la console |
| node-4 | dynamique         | À noter depuis la console |

```bash
cd /Volumes/NO\ NAME/BUREAU\ FNAC/EPITECH/KUBERNETES/t-clo-902_msc2026/kubernetes/scripts
bash update-ips.sh <IP_NODE2> <IP_NODE3> <IP_NODE4>
# Les 4 connexions SSH doivent afficher OK
```

---

## Étape 2 — Tunnel kubectl (OBLIGATOIRE en premier)

```bash
pkill -f "ssh -L 6443" 2>/dev/null
ssh -L 6443:10.2.53.35:6443 node-1 -N -f
kubectl get nodes   # doit retourner 4 nœuds Ready
```

---

## Étape 3 — Tunnels d'accès aux interfaces

```bash
# App Laravel
ssh -L 30080:localhost:30080 node-1 -N -f

# ArgoCD
ssh -L 30089:localhost:30089 node-1 -N -f

# Grafana + Prometheus + Alertmanager + Dashboard
kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80 &
kubectl port-forward -n monitoring svc/prometheus-operated 9090:9090 &
kubectl port-forward -n monitoring svc/kube-prometheus-stack-alertmanager 9093:9093 &
kubectl port-forward -n kubernetes-dashboard svc/kubernetes-dashboard 8443:443 &
```

---

## Accès aux interfaces

| Interface          | URL                          | Login                          |
|--------------------|------------------------------|--------------------------------|
| App Laravel        | http://app.kubequest.local:30080/api/counter/count | — |
| ArgoCD             | https://localhost:30089      | admin / `voir ~/.kube/argocd-pass` |
| Grafana            | http://localhost:3000        | admin / `voir ~/.kube/grafana-pass` |
| Prometheus         | http://localhost:9090        | —                              |
| Alertmanager       | http://localhost:9093        | —                              |
| Kubernetes Dashboard | https://localhost:8443     | Token (voir ci-dessous)        |

> **App Laravel** : ajouter `127.0.0.1 app.kubequest.local` dans `/etc/hosts` pour accéder via navigateur.
> ```bash
> echo "127.0.0.1 app.kubequest.local" | sudo tee -a /etc/hosts
> ```

> **ArgoCD / Dashboard** : certificat auto-signé → cliquer "Avancer quand même" dans le navigateur.

---

## Token Kubernetes Dashboard

Le token expire — en regénérer un si nécessaire :

```bash
kubectl create token dashboard-admin -n kubernetes-dashboard --duration=240000h
```

Copier le token affiché et le coller dans la page de login du Dashboard.

---

## Vérifications rapides

```bash
# Cluster OK ?
kubectl get nodes

# Pods app OK ?
kubectl get pods -n app

# ArgoCD sync OK ?
kubectl get application -n argocd kubequest-app

# Test de l'app
curl -s http://localhost:30080/api/counter/count -H "Host: app.kubequest.local"
```
