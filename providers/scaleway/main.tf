locals {
  naming_prefix = "${var.project_name}-${var.environment}"

  base_tags = concat(
    [
      "project:${var.project_name}",
      "environment:${var.environment}",
      "managed-by:terraform",
    ],
    var.tags
  )

  fqdn = var.subdomain == "" ? var.domain : "${var.subdomain}.${var.domain}"
}

provider "scaleway" {
  region          = var.scaleway_region
  zone            = var.scaleway_zone
  project_id      = var.scaleway_project_id != "" ? var.scaleway_project_id : null
  organization_id = var.scaleway_organization_id != "" ? var.scaleway_organization_id : null
}

provider "neon" {}
provider "mongodbatlas" {}

# ---------------- Storage (Scaleway Object Storage) ----------------

module "storage" {
  source = "./modules/storage"

  naming_prefix = local.naming_prefix
  region        = var.scaleway_region
  environment   = var.environment
  tags          = local.base_tags
}

# ---------------- Registry (Scaleway Container Registry) ----------------

module "registry" {
  source = "./modules/registry"

  naming_prefix = local.naming_prefix
  region        = var.scaleway_region
  tags          = local.base_tags
}

# ---------------- Database — Neon ----------------

module "database_neon" {
  source = "./modules/database-neon"

  naming_prefix       = local.naming_prefix
  environment         = var.environment
  region_id           = var.neon_project_region_id
  compute_min_cu      = var.neon_compute_min_cu
  compute_max_cu      = var.neon_compute_max_cu
  autosuspend_seconds = var.neon_autosuspend_seconds
}

# ---------------- Database — Atlas ----------------

module "database_atlas" {
  source = "./modules/database-atlas"

  naming_prefix  = local.naming_prefix
  environment    = var.environment
  org_id         = var.atlas_org_id
  cluster_tier   = var.atlas_cluster_tier
  cloud_provider = var.atlas_cloud_provider
  region         = var.atlas_region
  mongo_version  = var.atlas_mongo_version
}

# ---------------- Compute (Scaleway Instance) ----------------

module "compute" {
  source = "./modules/compute"

  naming_prefix       = local.naming_prefix
  environment         = var.environment
  zone                = var.scaleway_zone
  region              = var.scaleway_region
  instance_type       = var.instance_type
  instance_image      = var.instance_image
  root_volume_size_gb = var.instance_root_volume_size_gb
  fqdn                = local.fqdn

  registry_endpoint    = module.registry.registry_endpoint
  registry_credentials = module.registry.pull_secret_key

  postgres_url = module.database_neon.connection_string
  mongodb_url  = module.database_atlas.connection_string

  s3_endpoint         = module.storage.endpoint
  s3_region           = var.scaleway_region
  s3_artifacts_bucket = module.storage.artifacts_bucket_name
  s3_uploads_bucket   = module.storage.uploads_bucket_name
  s3_system_bucket    = module.storage.system_bucket_name
  s3_access_key       = module.storage.access_key
  s3_secret_key       = module.storage.secret_key

  backend_image_tag    = var.backend_image_tag
  biocompute_image_tag = var.biocompute_image_tag
  frontend_image_tag   = var.frontend_image_tag

  tags = local.base_tags
}

# ---------------- DNS (Scaleway Domain) ----------------

module "dns" {
  source = "./modules/dns"

  domain      = var.domain
  fqdn        = local.fqdn
  static_ip   = module.compute.public_ip
  environment = var.environment
}

# ---------------- Sovereign IAM domain (AXI-990 / FR2, FR3, NFR1, NFR3) ----------------

module "iam" {
  count  = var.use_sovereign_iam ? 1 : 0
  source = "./modules/iam"

  naming_prefix   = local.naming_prefix
  scaleway_region = var.scaleway_region
  tags            = local.base_tags
}

# ---------------- Runtime secrets (AXI-990 / FR3, CONTRACT §4) ----------------

locals {
  runtime_secrets = {
    DATABASE_URL = module.database_neon.connection_string
    MONGODB_URL  = module.database_atlas.connection_string
    S3_ENDPOINT  = module.storage.endpoint
  }
}

module "secrets" {
  count  = var.use_secret_manager ? 1 : 0
  source = "./modules/secrets"

  naming_prefix   = local.naming_prefix
  environment     = var.environment
  scaleway_region = var.scaleway_region
  secrets         = local.runtime_secrets
  tags            = local.base_tags
}

# ---------------- Private network + 3-tier SGs (AXI-991 / NFR7, AC11) ----------------

module "network" {
  count  = var.use_private_network ? 1 : 0
  source = "./modules/network"

  naming_prefix   = local.naming_prefix
  environment     = var.environment
  scaleway_region = var.scaleway_region
  tags            = local.base_tags
}

# ---------------- Data-at-rest CMK (AXI-991 / FR6, NFR5) ----------------

module "kms" {
  count  = var.use_cmk ? 1 : 0
  source = "./modules/kms"

  naming_prefix   = local.naming_prefix
  environment     = var.environment
  scaleway_region = var.scaleway_region
  tags            = local.base_tags
}
