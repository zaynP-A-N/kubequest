# Ce dossier contiendra les SealedSecrets chiffrés après exécution de setup-sealed-secrets.sh
#
# Fichiers qui seront créés ici (SAFE to commit — chiffrés avec la clé publique du cluster) :
#   sealed-secrets-cert.pem    → clé publique du controller (nécessaire pour re-chiffrer)
#   sealed-mysql-secret.yaml   → credentials MySQL chiffrés
#   sealed-app-secret.yaml     → APP_KEY Laravel chiffré
#
# IMPORTANT :
#   Ces fichiers ne peuvent être DÉCHIFFRÉS que par le Sealed Secrets controller
#   du cluster. Sans la clé privée du cluster, ils sont inutilisables.
#
# Pour initialiser :
#   bash kubernetes/scripts/setup-sealed-secrets.sh
