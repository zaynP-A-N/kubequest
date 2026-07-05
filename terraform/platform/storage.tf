# ─────────────────────────────────────────────────────────────────────────────
# Storage — local-path-provisioner
#
# Problème : Kubernetes ne sait pas créer de volumes persistants (PV) tout seul.
# Il a besoin d'un "provisioner" qui sait parler au storage sous-jacent.
#
# En prod AWS : le provisioner EBS (disques AWS) est intégré dans EKS.
# En lab kubeadm : aucun provisioner par défaut → PVC restent en "Pending".
#
# Solution : local-path-provisioner (Rancher)
#   - Crée des dossiers sur le disque local du nœud (/opt/local-path-provisioner/)
#   - Simple, zéro dépendance, parfait pour le lab
#   - Limitation : données liées à un nœud (pas de haute dispo du stockage)
#
# Ce que ça crée dans K8s :
#   - Une StorageClass "local-path" marquée comme défaut
#   - Un Deployment dans le namespace local-path-storage
#
# Après installation, un PersistentVolumeClaim (PVC) passera de Pending → Bound
# automatiquement dès qu'un pod le réclame.
# ─────────────────────────────────────────────────────────────────────────────

resource "null_resource" "local_path_provisioner" {
  triggers = {
    version = "v0.0.28"
  }

  # Étape 1 : installer le provisioner
  provisioner "local-exec" {
    command = "kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.28/deploy/local-path-storage.yaml"
  }

  # Étape 2 : marquer local-path comme StorageClass par défaut
  provisioner "local-exec" {
    command = "kubectl patch storageclass local-path -p '{\"metadata\": {\"annotations\":{\"storageclass.kubernetes.io/is-default-class\":\"true\"}}}'"
  }
}
