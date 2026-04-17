# Terraform EKS — Proof of Concept (non-exécutable en lab)

## Pourquoi ce dossier existe

Ce code Terraform représente ce qu'on **aurait fait** pour créer le cluster via
EKS en production. Il n'a pas pu être appliqué car les droits IAM nécessaires
ne sont pas accordés dans le compte école (649966626926, group-53).

## Droits IAM manquants (bloquants)

| Action IAM requise par Terraform | Erreur obtenue en CloudShell |
|---|---|
| `eks:CreateCluster` | `AccessDeniedException` |
| `iam:CreateRole` | `AccessDeniedException` |
| `iam:AttachRolePolicy` | `AccessDeniedException` |
| `ec2:CreateVpc` | `AccessDeniedException` |
| `ec2:AuthorizeSecurityGroupIngress` | `AccessDeniedException` |
| `ec2:RunInstances` | `AccessDeniedException` |

## Ce qu'on a fait à la place

- Cluster créé manuellement avec `kubeadm` sur les EC2 existantes (fournies par l'école)
- **Terraform est utilisé pour la Phase 3** (déploiement des services plateforme)
  via les providers `kubernetes` et `helm` qui se connectent au cluster existant →
  voir `/terraform/platform/`

## Pour tenter l'apply (depuis un compte avec droits complets)

```bash
cd terraform/eks-proof-of-concept
terraform init
terraform plan   # échouera avec AccessDeniedException sur votre compte école
terraform apply  # ne jamais lancer en lab — uniquement avec les bons droits
```
