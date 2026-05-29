# Troubleshooting

## 1. Ingress pods evicted / DiskPressure on ingress node

### Symptoms
- Many pods in `Evicted` status in `ingress-nginx` namespace
- `kubectl describe node ingress` shows `DiskPressure: True`
- New ingress pods stuck in `Pending` with error: `node had condition: [DiskPressure]`

### Diagnosis
```bash
# Check node conditions
kubectl describe node ingress | grep -A8 "Conditions:"

# Check disk usage on the ingress node
ssh ingress@192.168.175.137 "df -h /"
```

### Fix

**Step 1 — Clean evicted pods**
```bash
kubectl delete pods -n ingress-nginx --field-selector=status.phase==Failed
kubectl delete pods -n monitoring --field-selector=status.phase==Failed
```

**Step 2 — Free disk space on the ingress node (SSH in)**
```bash
ssh ingress@192.168.175.137

sudo crictl rmi --prune
sudo crictl rm $(sudo crictl ps -a -q --state Exited) 2>/dev/null || true
sudo journalctl --vacuum-time=3d
sudo journalctl --vacuum-size=100M
```

**Step 3 — Expand LVM if disk is still small (one-time fix)**
```bash
sudo lvextend -l +100%FREE /dev/mapper/ubuntu--vg-ubuntu--lv
sudo resize2fs /dev/mapper/ubuntu--vg-ubuntu--lv
df -h /
```

**Step 4 — Re-apply ingress values with resource limits**
```bash
helm upgrade ingress ingress-nginx/ingress-nginx \
  -n ingress-nginx \
  -f k8s/ingress-values.yaml
```

The file `k8s/ingress-values.yaml` sets `ephemeral-storage: 512Mi` as a hard limit so a single pod can never fill the disk again.

---

## 2. Accessing the app when ingress is not working

### Why `http://192.168.175.137:31804/` returns 404 or nothing

The Nginx Ingress routes by **Host header**. Accessing via raw IP sends `Host: 192.168.175.137` which matches no rule — the ingress doesn't know which app to route to.

### Option A — Hosts file (correct way)

Add this to `C:\Windows\System32\drivers\etc\hosts` (run as Administrator), or from WSL:
```bash
echo "192.168.175.137 app.local" | sudo tee -a /mnt/c/Windows/System32/drivers/etc/hosts
echo "192.168.175.137 grafana.local" | sudo tee -a /mnt/c/Windows/System32/drivers/etc/hosts
```

Then access:
- App: `http://app.local:31804`
- Grafana: `http://grafana.local:31804` (once `ingressClassName: nginx` is added to its ingress)

### Option B — Temporary NodePort on the app service (quick access)

```bash
# Add a NodePort directly on the Laravel service
kubectl patch svc laravel-app -n app \
  -p '{"spec":{"type":"NodePort","ports":[{"port":80,"targetPort":80,"nodePort":30090}]}}'
```

Access via: `http://192.168.175.134:30090` (kube2 worker node IP)

To revert back to ClusterIP:
```bash
kubectl patch svc laravel-app -n app \
  -p '{"spec":{"type":"ClusterIP","ports":[{"port":80,"targetPort":80}]}}'
```

### Current NodePorts (reference)

| Service | Node IP | Port | URL |
|---|---|---|---|
| Nginx Ingress HTTP | 192.168.175.137 | 31804 | requires Host header |
| Nginx Ingress HTTPS | 192.168.175.137 | 30474 | requires Host header |
| Grafana (direct) | 192.168.175.135 | 30557 | `http://192.168.175.135:30557` |
| Laravel app (NodePort) | 192.168.175.134 | 30090 | `http://192.168.175.134:30090` |

Grafana credentials: `admin` / `grafana`
