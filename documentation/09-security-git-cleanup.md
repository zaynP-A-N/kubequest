# Nettoyage de l'historique Git — Suppression des credentials exposés

## Contexte

Lors des phases 4 à 6 du projet, des credentials ont été committés en clair dans le dépôt GitLab :

| Credential exposé | Fichiers concernés |
|---|---|
| `REDACTED_DB_PASSWORD` / `REDACTED_DB_ROOT_PASSWORD` (MySQL) | `values.yaml`, `manifests/`, docs phases 4-6 |
| `APP_KEY` Laravel | `values.yaml`, `doc 06-phase4` |
| `REDACTED_ARGOCD_PASSWORD` (ArgoCD admin) | `doc 07-phase5`, `doc 00-routine-matin` |
| `REDACTED_GRAFANA_PASSWORD` (Grafana admin) | `doc 00-routine-matin`, `terraform/monitoring.tf` |
| Token GitLab `glpat-...` | `doc 05-comment-terraform` (URL remote) |

Ces credentials étaient visibles dans `git log`, `git show`, ou par simple `git clone`.

---

## Outil utilisé : `git-filter-repo`

`git-filter-repo` est l'outil **officiel recommandé** par Git pour réécrire l'historique. Il remplace l'ancienne commande `git filter-branch` qui était lente, dangereuse et dépréciée.

**Installation :**
```bash
brew install git-filter-repo
```

**Pourquoi pas `git filter-branch` ?**
- `git filter-branch` recrée les commits un par un via des scripts shell → très lent
- Il laisse des refs de backup (`refs/original/`) qui peuvent re-exposer les données
- Git lui-même affiche un warning "git filter-branch has a plethora of pitfalls" depuis 2019
- `git-filter-repo` est 10× à 100× plus rapide, sans refs résiduelles, et plus sûr

---

## Ce qui a été fait — étape par étape

### Étape 1 — Mise de côté des modifications en cours

```bash
git stash
```

Nécessaire pour que `git-filter-repo` ne se heurte pas à des fichiers modifiés non committés.

### Étape 2 — Création du fichier de remplacement

```bash
cat > /tmp/replacements.txt << 'EOF'
REDACTED_DB_PASSWORD==>REDACTED_DB_PASSWORD
REDACTED_DB_ROOT_PASSWORD==>REDACTED_DB_ROOT_PASSWORD
REDACTED_APP_KEY==>REDACTED_APP_KEY
REDACTED_ARGOCD_PASSWORD==>REDACTED_ARGOCD_PASSWORD
REDACTED_GRAFANA_PASSWORD==>REDACTED_GRAFANA_PASSWORD
REDACTED_GITLAB_TOKEN==>REDACTED_GITLAB_TOKEN
EOF
```

Ce fichier dit à `git-filter-repo` : "dans tout fichier, dans tout commit, remplace la chaîne à gauche de `==>` par la chaîne à droite".

### Étape 3 — Réécriture de l'historique

```bash
git filter-repo --replace-text /tmp/replacements.txt --force
```

**Ce que cette commande fait concrètement :**
1. Parcourt **chaque commit** de l'historique (20 commits dans notre cas)
2. Pour chaque commit, relit **chaque fichier** modifié
3. Remplace les patterns dans le contenu des fichiers
4. Recrée un nouveau commit avec un nouveau SHA (hash) — le contenu est propre
5. Met à jour toutes les branches et tags pour pointer sur les nouveaux commits
6. Supprime les anciens objets Git

> **Note** : Les SHA de tous les commits changent. `git log --oneline` montrera de nouveaux hashes.

**Output :**
```
Parsed 20 commits
New history written in 0.31 seconds; now repacking/cleaning...
HEAD is now at a781e6d feat(security): prepare Sealed Secrets setup...
```

> **Note macOS** : Des erreurs `non-monotonic index ._pack-*.idx` apparaissent pendant le nettoyage. Ce sont les fichiers metadata `._*` créés automatiquement par macOS sur les volumes NTFS/FAT. Ils ne bloquent pas le processus et sont résolus par :
> ```bash
> find .git/objects/pack -name "._*" -delete
> ```

> **Note** : `git-filter-repo` supprime automatiquement le remote `origin` comme mesure de sécurité pour éviter un push accidentel immédiat. Il faut le remettre manuellement.

### Étape 4 — Remise en place du remote

```bash
git remote add origin https://fotsodjeff:<TOKEN>@gitlab.com/fotsodjeff/t-clo-902_msc2026.git
```

### Étape 5 — Récupération des modifications et nettoyage des fichiers actuels

```bash
git stash pop
```

On nettoie aussi les fichiers en état actuel (pas seulement l'historique) :
- `values.yaml` : `appKey` et `password` → remplacés par `CHANGE_ME`/`SEALED`
- `00-routine-matin.md` : mots de passe ArgoCD et Grafana → remplacés par `voir ~/.kube/argocd-pass`

```bash
git add .
git commit -m "security: remove plaintext credentials from values.yaml and docs"
```

### Étape 6 — Force push

```bash
git push --force origin feat/initializeKubertenese-djeff-v1
```

**Pourquoi `--force` ?** L'historique local a été réécrit (nouveaux SHA), il diverge de l'historique GitLab. Un push normal serait rejeté avec `rejected (non-fast-forward)`. Le `--force` dit à GitLab "remplace ton historique par le mien".

**Sortie :**
```
 + 6db9212...6f3591a feat/initializeKubertenese-djeff-v1 -> feat/initializeKubertenese-djeff-v1 (forced update)
```

### Étape 7 — Vérification

```bash
# Vérifier que les credentials ne sont plus dans aucun commit
git log --all --oneline -S "REDACTED_DB_PASSWORD" 2>/dev/null
git log --all --oneline -S "REDACTED_APP_KEY" 2>/dev/null
git log --all --oneline -S "REDACTED_ARGOCD_PASSWORD" 2>/dev/null
# → Aucun résultat = credentials absents de tout l'historique ✓

# Vérifier que les fichiers actuels sont propres
grep -r "REDACTED_DB_PASSWORD\|REDACTED_APP_KEY\|REDACTED_ARGOCD_PASSWORD\|REDACTED_GRAFANA_PASSWORD" \
  --include="*.yaml" --include="*.md" --include="*.sh" . | \
  grep -v "REDACTED\|CHANGE_ME"
# → Aucun résultat ✓
```

---

## Protections mises en place pour l'avenir

### `.gitignore` mis à jour

Ajout de patterns qui bloquent les commits accidentels de fichiers sensibles :
```gitignore
values-secrets.yaml          # fichier Helm local avec vrais credentials
values-secrets.*.yaml
*.secret.yaml
.env
*.local                      # ex: CREDENTIALS.local
CREDENTIALS*
age.key                      # clés de chiffrement SOPS/age
*.kubeconfig
```

### `values-secrets.yaml.example`

Template commité en Git avec des `CHANGE_ME`. Workflow local :
```bash
cp values-secrets.yaml.example values-secrets.yaml
# éditer values-secrets.yaml avec les vrais mots de passe
# ce fichier est gitignored → jamais commité
```

### `CREDENTIALS.local`

Fichier local (gitignored) avec tous les credentials du projet. Il ne quitte jamais le Mac.

### Sealed Secrets (à déployer lundi)

```bash
bash kubernetes/scripts/setup-sealed-secrets.sh
```

Les credentials sont chiffrés asymétriquement par la clé publique du cluster. Seul le controller Sealed Secrets (dans le cluster) peut les déchiffrer. Les fichiers chiffrés sont safe à commiter.

---

## Ce qui reste à faire — Rotation des credentials

Les credentials ont été supprimés de l'historique Git, mais ils ont été visibles. Par mesure de sécurité, ils devraient être changés :

```bash
# 1. ArgoCD — changer le mot de passe admin
# Via l'interface : https://localhost:30089 → User Info → Update Password

# 2. GitLab Token — révoquer l'ancien et en créer un nouveau
# GitLab → Settings → Access Tokens → Revoke
# Puis mettre à jour la remote :
git remote set-url origin https://fotsodjeff:<NOUVEAU_TOKEN>@gitlab.com/fotsodjeff/t-clo-902_msc2026.git

# 3. Grafana — changer le mot de passe
# Interface Grafana → Profile → Change Password

# 4. MySQL — pour l'instant exposition interne seulement (port non exposé sur internet)
# Changer lors du passage en prod via Sealed Secrets
```

---

## En entreprise — comment ça se passe

| Outil | Usage |
|---|---|
| **git-filter-repo** | Même outil qu'on a utilisé, standard de l'industrie |
| **GitLab Secret Detection** | CI/CD qui bloque automatiquement les commits contenant des patterns de secrets |
| **truffleHog / gitleaks** | Scan de l'historique Git complet à la recherche de secrets |
| **pre-commit hooks** | Bloque localement un commit contenant un secret avant qu'il parte |
| **Sealed Secrets / Vault** | Les secrets ne transitent jamais en clair dans Git |

La règle d'or : **un secret commité = secret compromis**. Même supprimé de l'historique, on ne peut pas être sûr que GitLab ne l'a pas mis en cache, ou qu'un collaborateur n'a pas fait `git clone` entre-temps.
