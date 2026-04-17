# Phase 1 — Accès AWS et clé SSH

---

## Ce qu'on a fait

1. Récupéré la clé SSH privée depuis AWS SSM Parameter Store
2. Créé le fichier `~/.ssh/kubequest-group53.pem` avec les bonnes permissions
3. Configuré `~/.ssh/config` avec des alias pour les 4 nœuds
4. Identifié les 4 instances EC2 et leurs rôles (via les tags AWS)
5. Créé un script `update-ips.sh` pour gérer les IPs dynamiques
6. Créé le dépôt GitLab et versionné tous les scripts

---

## Pourquoi on l'a fait

### La clé SSH — principe fondamental de sécurité

SSH (Secure Shell) utilise un système de **cryptographie asymétrique** :

```
┌─────────────────────────────────────────────────────────────┐
│                  Comment fonctionne SSH                      │
│                                                              │
│  Tu possèdes :        Le serveur possède :                   │
│  🔐 clé PRIVÉE        🔑 clé PUBLIQUE (correspondante)       │
│  (jamais partagée)    (dans ~/.ssh/authorized_keys sur EC2)  │
│                                                              │
│  Connexion :                                                 │
│  ton Mac ──(challenge chiffré avec ta clé privée)──► EC2    │
│  EC2 vérifie avec la clé publique ──► connexion acceptée    │
└─────────────────────────────────────────────────────────────┘
```

**Jamais de mot de passe** → un mot de passe peut être deviné par brute-force. Une clé RSA 4096 bits nécessite des milliards d'années pour être cassée.

### Pourquoi `chmod 600` est obligatoire

```bash
chmod 600 ~/.ssh/kubequest-group53.pem
```

`600` signifie : lecture+écriture pour le propriétaire uniquement, rien pour les autres.

SSH refuse de fonctionner si la clé privée est lisible par d'autres utilisateurs. C'est une protection contre le vol de clé sur un système partagé. Si tu ne fais pas ce `chmod`, SSH affiche :
```
WARNING: UNPROTECTED PRIVATE KEY FILE!
Permissions 0644 are too open.
```

### ~/.ssh/config — pourquoi des alias ?

Sans config :
```bash
ssh -i ~/.ssh/kubequest-group53.pem -o StrictHostKeyChecking=no ec2-user@3.74.128.83
```

Avec config (après `Host node-1`) :
```bash
ssh node-1
```

C'est exactement ce que font les ingénieurs en production — personne ne tape les IPs à la main.

### AWS SSM Parameter Store — pourquoi stocker la clé là ?

Au lieu de distribuer la clé par email ou Slack (dangereux), l'école l'a stockée dans AWS Systems Manager Parameter Store de type `SecureString`. Seuls les utilisateurs IAM autorisés peuvent la lire. C'est une première approche de **gestion centralisée des secrets**.

---

## Les instances EC2 identifiées

### Tags AWS — le système de labelling

AWS utilise des **tags** (paires clé/valeur) pour identifier les ressources. On a découvert :

```
ec2-group-53-node-1 : Role=control-plane  IP publique fixe (Elastic IP) : 3.74.128.83
ec2-group-53-node-2 : Role=worker         IP publique dynamique
ec2-group-53-node-3 : Role=worker         IP publique dynamique
ec2-group-53-node-4 : Role=worker         IP publique dynamique
```

### Elastic IP vs IP dynamique

| Type | Comportement | Prix |
|---|---|---|
| **Elastic IP** | IP fixe, ne change pas au restart | Gratuit si attachée à une instance running |
| **IP dynamique** | Nouvelle IP à chaque redémarrage | Gratuit par défaut |

node-1 a une Elastic IP car c'est le control-plane — son IP doit être stable pour que les workers puissent le rejoindre.

### Le problème des IPs dynamiques

L'école éteint les instances chaque soir. Au redémarrage, node-2/3/4 ont de nouvelles IPs. C'est pourquoi on a créé :

```bash
bash kubernetes/scripts/update-ips.sh <IP2> <IP3> <IP4>
```

---

## Le système de persistance GitLab

### Pourquoi versionner les scripts ?

```
Sans Git :
  Lundi   → tu écris un script. Il est sur ton disque externe (USB).
  Mardi   → tu perds la clé USB. Tout est perdu.
  Ou :    → tu travailles à l'école sur un autre Mac. Rien n'est là.

Avec Git + GitLab :
  Lundi   → git commit + git push → script sauvegardé sur GitLab
  Mardi   → sur n'importe quel Mac : git clone → tu retrouves tout
  Toujours → git log → tu vois l'historique de chaque changement
```

### Le bug des fichiers `._*` macOS

On a rencontré l'erreur :
```
error: non-monotonic index .git/objects/pack/._pack-53ba10a4....idx
```

**Cause** : macOS crée automatiquement des fichiers `._` (AppleDouble) dans chaque dossier sur les volumes externes (clé USB, disque externe). Ces fichiers stockent les métadonnées macOS (icônes, attributs étendus). Git les confond avec ses propres fichiers et son index se corrompt.

**Solution** :
```bash
find .git/objects/pack -name "._*" -delete
```

**Protection permanente dans `.gitignore`** :
```
._*
.DS_Store
.AppleDouble
```

---

## Les commandes clés expliquées

### Récupérer la clé SSH depuis SSM

```bash
aws ssm get-parameter \
  --name "/kubequest/group-53/ssh-private-key" \
  --with-decryption \
  --query "Parameter.Value" \
  --output text > ~/.ssh/kubequest-group53.pem
```

| Option | Rôle |
|---|---|
| `--with-decryption` | Déchiffre le `SecureString` (nécessite permission SSM) |
| `--query "Parameter.Value"` | Extrait uniquement la valeur (pas les métadonnées JSON) |
| `--output text` | Sortie brute sans guillemets JSON |
| `> fichier` | Redirige la sortie dans un fichier |

### Tester la connexion SSH

```bash
ssh -o ConnectTimeout=8 -o BatchMode=yes node-1 hostname
```

| Option | Rôle |
|---|---|
| `ConnectTimeout=8` | Abandonne après 8 secondes si pas de réponse |
| `BatchMode=yes` | Pas de prompt interactif — échoue proprement si pas de clé |

---

## En entreprise (production réelle)

### Gestion des clés SSH en prod

En production, **personne ne partage des clés SSH privées**. On utilise :

1. **AWS EC2 Instance Connect** → génère une clé temporaire (60 secondes) à la demande
2. **AWS Systems Manager Session Manager** → accès shell sans SSH ni port 22 ouvert
3. **Bastion host** → une seule machine accessible depuis internet, puis rebond interne
4. **HashiCorp Vault SSH** → signature de clés à durée limitée (ex : 1h)

### Infrastructure as Code pour les IPs

En production, les IPs ne changent pas car :
- On utilise **Terraform** pour créer les instances avec des Elastic IPs
- Les noms DNS internes (Route53) pointent toujours vers la bonne IP
- Les workers rejoignent le cluster via DNS, pas par IP

```hcl
# Exemple Terraform (ce qu'on ferait en prod)
resource "aws_eip" "node" {
  count    = 4
  instance = aws_instance.nodes[count.index].id
}
```

### GitLab en entreprise

En entreprise, GitLab/GitHub est utilisé pour :
- **CI/CD pipelines** → les scripts s'exécutent automatiquement à chaque commit
- **Branch protection** → personne ne push directement sur `main`
- **Merge requests** → tout changement est reviewé par un pair
- **Secret scanning** → détecte automatiquement si une clé/password est commité

---

## En lab (ce qu'on a fait ici et pourquoi)

| Ce qu'on a fait | Ce qu'on ferait en prod | Raison |
|---|---|---|
| Clé SSH stockée en fichier `.pem` | AWS Session Manager / Vault | Accès simplifié pour apprendre |
| IPs mises à jour manuellement | Elastic IPs ou DNS | Pas de droits pour créer des EIPs supplémentaires |
| GitLab public | GitLab privé avec CI/CD | Projet école, pas de données sensibles |

---

## Ce que tu as appris dans cette phase

- La cryptographie asymétrique et pourquoi SSH est plus sûr qu'un mot de passe
- Les permissions Unix (`chmod 600`) et leur importance sécurité
- AWS SSM Parameter Store comme gestionnaire de secrets basique
- La différence entre Elastic IP et IP dynamique sur AWS EC2
- Pourquoi Git + remote (GitLab/GitHub) est indispensable pour un DevOps
- Comment déboguer un repo Git corrompu par des fichiers macOS
