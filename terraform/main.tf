variable "environment" {
  type = string
}

variable "gcp_region" {
  type = string
}

variable "gcp_project" {
  type = string
}

variable "aws_region" {
  type = string
}

variable "aws_profile" {
  type    = string
  default = "leuswest2"
}

variable "machine_type" {
  type    = string
  default = "e2.small"
}

variable "peer_share_processor_names" {
  type = list(string)
}

variable "ingestors" {
  type        = map(string)
  description = "Map of ingestor names to the URL where their global manifest may be found."
}

variable "manifest_domain" {
  type        = string
  description = "Domain (plus optional relative path) to which this environment's global and specific manifests should be uploaded."
}

variable "peer_share_processor_manifest_domain" {
  type = string
}

terraform {
  backend "gcs" {}

  required_version = ">= 0.13.3"
}

data "terraform_remote_state" "state" {
  backend = "gcs"

  workspace = "${var.environment}-${var.gcp_region}"

  config = {
    bucket = "${var.environment}-${var.gcp_region}-prio-terraform"
  }
}

data "google_client_config" "current" {}

provider "google-beta" {
  # We use the google-beta provider so that we can use configuration fields that
  # aren't in the GA google provider. Google resources must explicitly opt into
  # this provider with `provider = google-beta` or they will not inherit values
  # appropriately.
  # https://www.terraform.io/docs/providers/google/guides/provider_versions.html
  # This will use "Application Default Credentials". Run `gcloud auth
  # application-default login` to generate them.
  # https://www.terraform.io/docs/providers/google/guides/provider_reference.html#credentials
  region  = var.gcp_region
  project = var.gcp_project
}

provider "aws" {
  # aws_s3_bucket resources will be created in the region specified here
  # https://github.com/hashicorp/terraform/issues/12512
  region  = var.aws_region
  profile = var.aws_profile
}

provider "kubernetes" {
  host                   = module.gke.cluster_endpoint
  cluster_ca_certificate = base64decode(module.gke.certificate_authority_data)
  token                  = data.google_client_config.current.access_token
  load_config_file       = false
}

module "manifest" {
  source      = "./modules/manifest"
  environment = var.environment
  gcp_region  = var.gcp_region
  domain      = var.manifest_domain
}

module "gke" {
  source          = "./modules/gke"
  environment     = var.environment
  resource_prefix = "prio-${var.environment}"
  gcp_region      = var.gcp_region
  gcp_project     = var.gcp_project
  machine_type    = var.machine_type
}

# For each peer data share processor, we will receive ingestion batches from two
# ingestion servers. We create a distinct data share processor instance for each
# (peer, ingestor) pair.
# First, we fetch the ingestor global manifests, which yields a map of ingestor
# name => HTTP content.
data "http" "ingestor_global_manifests" {
  for_each = var.ingestors
  url      = "https://${each.value}/global-manifest.json"
}

# Then we fetch the single global manifest for all the peer share processors.
data "http" "peer_share_processor_global_manifest" {
  url = "https://${var.peer_share_processor_manifest_domain}/global-manifest.json"
}

# While we create a distinct data share processor for each (ingestor, peer data
# share processor) pair, we only create one packet decryption key for each peer
# data share processor, and use it for all ingestors. Since the secret must be
# in a namespace and accessible from both data share processors, that means both
# data share processors must be in a single Kubernetes namespace, which we
# create here and pass into the data share processor module.
resource "kubernetes_namespace" "namespaces" {
  for_each = toset(var.peer_share_processor_names)
  metadata {
    name = each.key
    annotations = {
      environment = var.environment
    }
  }
}

resource "kubernetes_secret" "ingestion_packet_decryption_keys" {
  for_each = toset(var.peer_share_processor_names)
  metadata {
    name      = "${var.environment}-${each.key}-ingestion-packet-decryption-key"
    namespace = kubernetes_namespace.namespaces[each.key].metadata[0].name
  }

  data = {
    # See comment on batch_signing_key, above, about the initial value here.
    decryption_key = "not-a-real-key"
  }

  lifecycle {
    ignore_changes = [
      data["decryption_key"]
    ]
  }
}

# Now, we take the set product of peer share processor names x ingestor names to
# get the config values for all the data share processors we need to create.
locals {
  peer_ingestor_pairs = {
    for pair in setproduct(toset(var.peer_share_processor_names), keys(var.ingestors)) :
    "${pair[0]}-${pair[1]}" => {
      kubernetes_namespace                    = kubernetes_namespace.namespaces[pair[0]].metadata[0].name
      packet_decryption_key_kubernetes_secret = kubernetes_secret.ingestion_packet_decryption_keys[pair[0]].metadata[0].name
      ingestor_aws_role_arn                   = lookup(jsondecode(data.http.ingestor_global_manifests[pair[1]].body), "aws-iam-entity", "")
      ingestor_gcp_service_account_id         = lookup(jsondecode(data.http.ingestor_global_manifests[pair[1]].body), "google-service-account", "")
    }
  }
}

module "data_share_processors" {
  for_each                                = local.peer_ingestor_pairs
  source                                  = "./modules/data_share_processor"
  environment                             = var.environment
  data_share_processor_name               = each.key
  gcp_project                             = var.gcp_project
  ingestor_aws_role_arn                   = each.value.ingestor_aws_role_arn
  ingestor_google_service_account_id      = each.value.ingestor_gcp_service_account_id
  peer_share_processor_aws_account_id     = jsondecode(data.http.peer_share_processor_global_manifest.body).aws-account-id
  kubernetes_namespace                    = each.value.kubernetes_namespace
  packet_decryption_key_kubernetes_secret = each.value.packet_decryption_key_kubernetes_secret

  depends_on = [module.gke]
}

output "manifest_bucket" {
  value = module.manifest.bucket
}

output "gke_kubeconfig" {
  value = "Run this command to update your kubectl config: gcloud container clusters get-credentials ${module.gke.cluster_name} --region ${var.gcp_region}"
}

output "specific_manifests" {
  value = { for v in module.data_share_processors : v.data_share_processor_name => {
    kubernetes-namespace = v.kubernetes_namespace
    specific-manifest    = v.specific_manifest
    }
  }
}
