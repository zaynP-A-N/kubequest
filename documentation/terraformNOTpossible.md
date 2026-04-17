
# Commande effectué 
sh node-1 << 'EOF'
echo "=== TEST 1 : Identité IAM ==="
aws sts get-caller-identity --region eu-central-1 2>&1

echo ""
echo "=== TEST 2 : Créer cluster EKS ==="
aws eks create-cluster \
  --name test-perm-check \
  --kubernetes-version 1.29 \
  --role-arn arn:aws:iam::649966626926:role/test \
  --resources-vpc-config subnetIds=subnet-00000000000000000 \
  --region eu-central-1 2>&1

echo ""
echo "=== TEST 3 : Créer rôle IAM ==="
aws iam create-role \
  --role-name test-perm-check \
  --assume-role-policy-document '{"Version":"2012-10-17","Statement":[]}' 2>&1

echo ""
echo "=== TEST 4 : Modifier Security Group ==="
SG=$(aws ec2 describe-security-groups --region eu-central-1 \
  --query 'SecurityGroups[0].GroupId' --output text 2>&1)
echo "Security Group trouvé : $SG"
aws ec2 authorize-security-group-ingress \
  --group-id "$SG" \
  --protocol tcp --port 6443 --cidr 0.0.0.0/0 \
  --region eu-central-1 2>&1
EOF






# Resultat 
Pseudo-terminal will not be allocated because stdin is not a terminal.
** WARNING: connection is not using a post-quantum key exchange algorithm.
** This session may be vulnerable to "store now, decrypt later" attacks.
** The server may need to be upgraded. See https://openssh.com/pq.html

A newer release of "Amazon Linux" is available.
  Version 2023.10.20260325:
  Version 2023.10.20260330:
  Version 2023.11.20260406:
Run "/usr/bin/dnf check-release-update" for full release and version update info
   ,     #_
   ~\_  ####_        Amazon Linux 2023
  ~~  \_#####\
  ~~     \###|
  ~~       \#/ ___   https://aws.amazon.com/linux/amazon-linux-2023
   ~~       V~' '->
    ~~~         /
      ~~._.   _/
         _/ _/
       _/m/'
=== TEST 1 : Identité IAM ===
{
    "UserId": "AROAZOVIHVBXNFXOPYXGI:i-0b005e3757192d4b1",
    "Account": "649966626926",
    "Arn": "arn:aws:sts::649966626926:assumed-role/kubequest-epitech-ec2-role/i-0b005e3757192d4b1"
}

=== TEST 2 : Créer cluster EKS ===

An error occurred (AccessDeniedException) when calling the CreateCluster operation: User: arn:aws:sts::649966626926:assumed-role/kubequest-epitech-ec2-role/i-0b005e3757192d4b1 is not authorized to perform: eks:CreateCluster on resource: arn:aws:eks:eu-central-1:649966626926:cluster/test-perm-check because no identity-based policy allows the eks:CreateCluster action

=== TEST 3 : Créer rôle IAM ===

An error occurred (AccessDenied) when calling the CreateRole operation: User: arn:aws:sts::649966626926:assumed-role/kubequest-epitech-ec2-role/i-0b005e3757192d4b1 is not authorized to perform: iam:CreateRole on resource: arn:aws:iam::649966626926:role/test-perm-check because no identity-based policy allows the iam:CreateRole action

=== TEST 4 : Modifier Security Group ===
Security Group trouvé : 
An error occurred (UnauthorizedOperation) when calling the DescribeSecurityGroups operation: You are not authorized to perform this operation. User: arn:aws:sts::649966626926:assumed-role/kubequest-epitech-ec2-role/i-0b005e3757192d4b1 is not authorized to perform: ec2:DescribeSecurityGroups because no identity-based policy allows the ec2:DescribeSecurityGroups action

An error occurred (InvalidGroupId.Malformed) when calling the AuthorizeSecurityGroupIngress operation: The security-group ID '
An error occurred (UnauthorizedOperation) when calling the DescribeSecurityGroups operation: You are not authorized to perform this operation. User: arn:aws:sts::649966626926:assumed-role/kubequest-epitech-ec2-role/i-0b005e3757192d4b1 is not authorized to perform: ec2:DescribeSecurityGroups because no identity-based policy allows the ec2:DescribeSecurityGroups action' is malformed