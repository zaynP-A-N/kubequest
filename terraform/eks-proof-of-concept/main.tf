terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "eu-central-1"
  # NOTE : Ce code nécessite des droits IAM qui ne sont PAS disponibles
  # dans le compte école 649966626926 (group-53).
  # Lancer terraform apply ici retourne AccessDeniedException.
}

# ─────────────────────────────────────────────────────────────────────────────
# BLOC 1 : Rôle IAM pour EKS
# Droit requis : iam:CreateRole, iam:AttachRolePolicy
# Erreur école : AccessDeniedException
# ─────────────────────────────────────────────────────────────────────────────
resource "aws_iam_role" "eks_cluster" {
  name = "kubequest-eks-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.eks_cluster.name
}

# ─────────────────────────────────────────────────────────────────────────────
# BLOC 2 : VPC et Subnets
# Droit requis : ec2:CreateVpc, ec2:CreateSubnet, ec2:CreateInternetGateway
# Erreur école : AccessDeniedException
# ─────────────────────────────────────────────────────────────────────────────
resource "aws_vpc" "kubequest" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = { Name = "kubequest-vpc" }
}

resource "aws_subnet" "private_az1" {
  vpc_id            = aws_vpc.kubequest.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = "eu-central-1a"

  tags = { Name = "kubequest-private-1a" }
}

resource "aws_subnet" "private_az2" {
  vpc_id            = aws_vpc.kubequest.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = "eu-central-1b"

  tags = { Name = "kubequest-private-1b" }
}

# ─────────────────────────────────────────────────────────────────────────────
# BLOC 3 : Cluster EKS
# Droit requis : eks:CreateCluster
# Erreur école : AccessDeniedException
# ─────────────────────────────────────────────────────────────────────────────
resource "aws_eks_cluster" "kubequest" {
  name     = "kubequest"
  role_arn = aws_iam_role.eks_cluster.arn
  version  = "1.29"

  vpc_config {
    subnet_ids = [
      aws_subnet.private_az1.id,
      aws_subnet.private_az2.id,
    ]
    endpoint_private_access = true
    endpoint_public_access  = true
  }

  # En prod : activer logging
  enabled_cluster_log_types = ["api", "audit", "authenticator"]

  depends_on = [aws_iam_role_policy_attachment.eks_cluster_policy]

  tags = { Environment = "production", Project = "kubequest" }
}

# ─────────────────────────────────────────────────────────────────────────────
# BLOC 4 : Node Group (workers)
# Droit requis : eks:CreateNodegroup, ec2:RunInstances
# Erreur école : AccessDeniedException
# ─────────────────────────────────────────────────────────────────────────────
resource "aws_iam_role" "node_group" {
  name = "kubequest-eks-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_eks_node_group" "workers" {
  cluster_name    = aws_eks_cluster.kubequest.name
  node_group_name = "workers"
  node_role_arn   = aws_iam_role.node_group.arn
  subnet_ids      = [aws_subnet.private_az1.id, aws_subnet.private_az2.id]

  instance_types = ["t4g.medium"] # ARM64 — même type que les EC2 école

  scaling_config {
    desired_size = 3
    max_size     = 5
    min_size     = 1
  }

  # En prod : utiliser des managed node groups avec auto-scaling
  depends_on = [aws_iam_role.node_group]
}
