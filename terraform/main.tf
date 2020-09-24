variable "infra_name" {
  type = string
}

variable "aws_region" {
  type = string
}

variable "aws_profile" {
  type = string
}

variable "eks_version" {
  type = string
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "subnets" {
  type    = list(string)
  default = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
}

variable "s3_kms_key_id" {
  type        = string
  description = "This is a KMS Alias ARN to be provided via the CLI"
}

variable "instance_type" {
  type    = string
  default = "t2.small"
}

variable "peer_share_processor_names" {
  type = list(string)
}

variable "container_registry" {
  type = string
}

variable "execution_manager_image" {
  type = string
}

variable "execution_manager_version" {
  type = string
}

terraform {
  backend "s3" {}

  required_version = ">= 0.13.3"
}

data "terraform_remote_state" "vpc" {
  backend = "s3"

  // This must map to the workspace from the Makefile
  workspace = "${var.infra_name}-${var.aws_region}"

  // This must map to the bucket and key from the Makefile
  config = {
    profile        = var.aws_profile
    region         = var.aws_region
    bucket         = "${var.infra_name}-${var.aws_region}-prio-facilitator-terraform"
    key            = "${var.infra_name}/vpc/terraform.tfstate"
    dynamodb_table = "${var.infra_name}-${var.aws_region}-prio-facilitator-terraform"
    acl            = "private"
    encrypt        = true
    kms_key_id     = var.s3_kms_key_id
  }
}

provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.certificate_authority_data)
  token                  = module.eks.cluster_auth_token
  load_config_file       = false
}

resource "aws_vpc" "cluster" {
  cidr_block                       = "10.0.0.0/16"
  assign_generated_ipv6_cidr_block = "true"
  enable_dns_support               = true
  enable_dns_hostnames             = true

  tags = {
    Name                                           = "prio-${var.infra_name}"
    "kubernetes.io/cluster/prio-${var.infra_name}" = "shared"
  }

  lifecycle {
    create_before_destroy = true
    ignore_changes = [
      tags
    ]
  }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.cluster.id

  tags = {
    Name = "prio-${var.infra_name}"
  }
}

data "aws_availability_zones" "available" {}

resource "aws_subnet" "subnets" {
  count             = length(var.subnets)
  vpc_id            = aws_vpc.cluster.id
  cidr_block        = var.subnets[count.index]
  ipv6_cidr_block   = cidrsubnet(aws_vpc.cluster.ipv6_cidr_block, 8, count.index)
  availability_zone = data.aws_availability_zones.available.names[count.index]
  # Assign public IPs to workers so they can reach external container registries
  # and also reach cluster API server over public internet.
  map_public_ip_on_launch         = true
  assign_ipv6_address_on_creation = true

  tags = {
    Name = "prio-${var.infra_name}-${replace(data.aws_availability_zones.available.names[count.index], "-", "")}"
    # https://docs.aws.amazon.com/eks/latest/userguide/network_reqs.html#vpc-subnet-tagging
    "kubernetes.io/cluster/prio-${var.infra_name}" = "shared"
  }

  lifecycle {
    create_before_destroy = true
    # kubernetes inserts tags
    ignore_changes = [
      tags
    ]
  }
}

resource "aws_route_table" "public" {
  count  = length(aws_subnet.subnets)
  vpc_id = aws_vpc.cluster.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  route {
    ipv6_cidr_block = "::/0"
    gateway_id      = aws_internet_gateway.igw.id
  }

  tags = {
    Name = "prio-${var.infra_name}"
  }
}

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.subnets)
  subnet_id      = element(aws_subnet.subnets.*.id, count.index)
  route_table_id = element(aws_route_table.public.*.id, count.index)
}

module "eks" {
  source        = "./modules/eks/"
  vpc_id        = aws_vpc.cluster.id
  infra_name    = var.infra_name
  subnet_ids    = aws_subnet.subnets.*.id
  instance_type = var.instance_type
  aws_region    = var.aws_region
  eks_version   = var.eks_version
}

module "kubernetes" {
  source                     = "./modules/kubernetes/"
  container_registry         = var.container_registry
  execution_manager_image    = var.execution_manager_image
  execution_manager_version  = var.execution_manager_version
  peer_share_processor_names = var.peer_share_processor_names
  infra_name                 = var.infra_name

  depends_on = [module.eks]
}

output "eks_kubeconfig" {
  value = "Place the output of this command into ~/.kube/config\n==========================================================\n${module.eks.kubeconfig}\n=========================================================="
}
