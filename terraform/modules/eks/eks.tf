variable "infra_name" {
  type = string
}

variable "instance_type" {
  type = string
}

variable "subnet_ids" {
  type = list
}

variable "vpc_id" {
  type = string
}

variable "aws_region" {
  type = string
}

variable "eks_version" {
  type = string
}

resource "aws_eks_node_group" "workers" {
  cluster_name    = aws_eks_cluster.cluster.name
  node_group_name = "prio-${var.infra_name}-workers"
  node_role_arn   = aws_iam_role.worker.arn
  subnet_ids      = var.subnet_ids
  instance_types  = [var.instance_type]

  scaling_config {
    desired_size = 3
    max_size     = 4
    min_size     = 1
  }

  tags = {
    Name = var.infra_name
  }
}

resource "aws_iam_role" "worker" {
  name = "prio-${var.infra_name}-worker"

  assume_role_policy = <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
POLICY
}

resource "aws_iam_role_policy_attachment" "k8s-node-AmazonEKSWorkerNodePolicy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.worker.name
}

resource "aws_iam_role_policy_attachment" "k8s-node-AmazonEKS_CNI_Policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.worker.name
}

resource "aws_iam_role_policy_attachment" "k8s-node-AmazonEC2ContainerRegistryReadOnly" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.worker.name
}

resource "aws_security_group" "k8s-manager" {
  name        = "prio-${var.infra_name}-eks-k8s-manager"
  description = "Cluster communication with worker nodes"
  vpc_id      = var.vpc_id

  # https://docs.aws.amazon.com/eks/latest/userguide/sec-group-reqs.html
  ingress {
    from_port = 0
    to_port   = 0
    protocol  = "-1"
    self      = true
  }

  # Allow worker nodes to reach out to the internet.
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    ipv6_cidr_blocks = ["::/0"]
  }

  tags = {
    Name = "${var.infra_name}-manager"
  }
}

resource "aws_eks_cluster" "cluster" {
  name     = "prio-${var.infra_name}"
  role_arn = aws_iam_role.k8s-manager.arn
  version  = var.eks_version

  vpc_config {
    security_group_ids      = ["${aws_security_group.k8s-manager.id}"]
    subnet_ids              = var.subnet_ids
    endpoint_public_access  = true
    endpoint_private_access = true
  }

  enabled_cluster_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  depends_on = [
    aws_iam_role_policy_attachment.k8s-manager-AmazonEKSClusterPolicy,
    aws_iam_role_policy_attachment.k8s-manager-AmazonEKSServicePolicy,
    aws_cloudwatch_log_group.control-plane
  ]

  tags = {
    Name = var.infra_name
  }
}

resource "aws_iam_role" "k8s-manager" {
  name = "prio-${var.infra_name}-manager"

  assume_role_policy = <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "eks.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
POLICY
}

resource "aws_iam_role_policy_attachment" "k8s-manager-AmazonEKSClusterPolicy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.k8s-manager.name
}

resource "aws_iam_role_policy_attachment" "k8s-manager-AmazonEKSServicePolicy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSServicePolicy"
  role       = aws_iam_role.k8s-manager.name
}

resource "aws_cloudwatch_log_group" "control-plane" {
  name              = "${var.infra_name}-control-plane"
  retention_in_days = 7
  kms_key_id        = aws_kms_key.cloudwatch.arn

  tags = {
    Name = var.infra_name
  }

  depends_on = [
    aws_kms_key.cloudwatch
  ]
}

data "aws_caller_identity" "current" {}

resource "aws_kms_key" "cloudwatch" {
  description             = "Terraform generated KMS key for EKS control plane CloudWatch logging prio-${var.infra_name}-cloudwatch"
  key_usage               = "ENCRYPT_DECRYPT"
  deletion_window_in_days = "30"
  is_enabled              = true
  enable_key_rotation     = true

  policy = <<EOF
{
  "Version" : "2012-10-17",
  "Id" : "key-default-1",
  "Statement" : [ {
      "Sid" : "Enable IAM User Permissions",
      "Effect" : "Allow",
      "Principal" : {
        "AWS" : "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
      },
      "Action" : "kms:*",
      "Resource" : "*"
    },
    {
      "Effect": "Allow",
      "Principal": { "Service": "logs.${var.aws_region}.amazonaws.com" },
      "Action": [
        "kms:Encrypt*",
        "kms:Decrypt*",
        "kms:ReEncrypt*",
        "kms:GenerateDataKey*",
        "kms:Describe*"
      ],
      "Resource": "*"
    }
  ]
}
EOF

  tags = {
    Name = var.infra_name
  }
}

locals {
  kubeconfig = <<KUBECONFIG

apiVersion: v1
clusters:
- cluster:
    server: ${aws_eks_cluster.cluster.endpoint}
    certificate-authority-data: ${aws_eks_cluster.cluster.certificate_authority.0.data}
  name: prio-${var.infra_name}-cluster
contexts:
- context:
    cluster: prio-${var.infra_name}-cluster
    user: prio-${var.infra_name}-cluster
  name: prio-${var.infra_name}-cluster
current-context: prio-${var.infra_name}-cluster
kind: Config
preferences: {}
users:
- name: prio-${var.infra_name}-cluster
  user:
    exec:
      apiVersion: client.authentication.k8s.io/v1alpha1
      command: aws
      args:
        - "eks"
        - "get-token"
        - "--cluster-name"
        - "prio-${var.infra_name}"
        - "--region"
        - "${var.aws_region}"
      env:
        - name: AWS_STS_REGIONAL_ENDPOINTS
          value: regional
KUBECONFIG
}

data "aws_eks_cluster_auth" "cluster" {
  name = "prio-${var.infra_name}"

  depends_on = [
    aws_eks_cluster.cluster
  ]
}

output "kubeconfig" {
  value = local.kubeconfig
}

output "cluster_endpoint" {
  value = aws_eks_cluster.cluster.endpoint
}

output "certificate_authority_data" {
  value = aws_eks_cluster.cluster.certificate_authority.0.data
}

output "cluster_auth_token" {
  value = data.aws_eks_cluster_auth.cluster.token
}
