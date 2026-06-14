locals {
  naming_prefix = "${var.project_name}-${var.environment}"

  base_tags = merge(
    {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
    },
    var.common_tags
  )

  fqdn = var.subdomain == "" ? var.domain : "${var.subdomain}.${var.domain}"
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = local.base_tags
  }
}

# CloudFront + ACM are global services that require us-east-1 for the cert
# (CloudFront only consumes ACM certs from us-east-1). Aliased provider used
# by the `edge` module; the rest of the stack stays in var.aws_region.
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"

  default_tags {
    tags = local.base_tags
  }
}

provider "neon" {}
provider "mongodbatlas" {}

# ---------------- KMS (customer-managed key for data-at-rest) ----------------

module "kms" {
  source = "./modules/kms"

  naming_prefix = local.naming_prefix
  environment   = var.environment
  tags          = local.base_tags
}

# ---------------- Storage (S3) ----------------

module "storage" {
  source = "./modules/storage"

  naming_prefix = local.naming_prefix
  environment   = var.environment
  kms_key_arn   = module.kms.key_arn
  tags          = local.base_tags
}

# ---------------- Registry (ECR) ----------------
# ECR repositories are shared across environments at the AWS account level.
# Only the production environment creates them; dev/staging reuse via data sources.

module "registry" {
  source = "./modules/registry"

  create_repositories = coalesce(var.create_ecr_repositories, var.environment == "production")
  project_name        = var.project_name
  tags                = local.base_tags
}

# ---------------- Secrets (SSM Parameter Store) ----------------

module "secrets" {
  source = "./modules/secrets"

  naming_prefix = local.naming_prefix
  environment   = var.environment

  # Lightsail SSM-read role only for the legacy compute path; EC2/HDS uses its own profile.
  create_lightsail_iam = var.use_legacy_stack

  # Legacy stack -> Neon/Atlas; new HDS stack -> RDS + in-region Mongo + ElastiCache (FR2/FR3/FR5).
  postgres_url        = var.use_legacy_stack ? try(module.database_neon[0].connection_string, "") : try(module.database_rds[0].connection_string, "")
  mongodb_url         = var.use_legacy_stack ? try(module.database_atlas[0].connection_string, "") : ""
  use_inregion_mongo  = !var.use_legacy_stack
  redis_url           = var.use_hds_data_stack ? try(module.cache_redis[0].redis_url, "") : ""
  publish_redis_url   = var.use_hds_data_stack
  s3_artifacts_bucket = module.storage.artifacts_bucket_name
  s3_uploads_bucket   = module.storage.uploads_bucket_name
  s3_system_bucket    = module.storage.system_bucket_name
  s3_region           = var.aws_region
  ecr_registry        = module.registry.registry_url
  domain              = local.fqdn
  fqdn                = local.fqdn
  tags                = local.base_tags
}

# ---------------- Database — Neon (Postgres) ----------------

module "database_neon" {
  source = "./modules/database-neon"
  count  = var.use_legacy_stack ? 1 : 0

  naming_prefix             = local.naming_prefix
  environment               = var.environment
  region_id                 = var.neon_project_region_id
  compute_min_cu            = var.neon_compute_min_cu
  compute_max_cu            = var.neon_compute_max_cu
  autosuspend_seconds       = var.neon_autosuspend_seconds
  history_retention_seconds = var.neon_history_retention_seconds
}

# ---------------- Database — Atlas (MongoDB) ----------------

module "database_atlas" {
  source = "./modules/database-atlas"
  count  = var.use_legacy_stack ? 1 : 0

  naming_prefix  = local.naming_prefix
  environment    = var.environment
  org_id         = var.atlas_org_id
  cluster_tier   = var.atlas_cluster_tier
  cloud_provider = var.atlas_cloud_provider
  region         = var.atlas_region
  mongo_version  = var.atlas_mongo_version
}

# ---------------- HDS data stack (parallel stand-up) — FR1 / FR2 / NFR7 ----------------
# Gated by var.use_hds_data_stack. Stands up the new private network + RDS Postgres
# alongside the live stack so it can be migrated and tested before cutover (S13).

module "network" {
  source = "./modules/network"
  count  = var.use_hds_data_stack ? 1 : 0

  naming_prefix = local.naming_prefix
  environment   = var.environment
  vpc_cidr      = var.vpc_cidr
  tags          = local.base_tags
}

module "database_rds" {
  source = "./modules/database-rds"
  count  = var.use_hds_data_stack ? 1 : 0

  naming_prefix          = local.naming_prefix
  environment            = var.environment
  kms_key_arn            = module.kms.key_arn
  subnet_ids             = module.network[0].private_subnet_ids
  vpc_security_group_ids = [module.network[0].data_security_group_id]
  instance_class         = var.rds_instance_class
  allocated_storage      = var.rds_allocated_storage
  multi_az               = var.rds_multi_az
  tags                   = local.base_tags
}

# Provider-native EC2 compute (replaces Lightsail when use_ec2_compute = true).
module "compute_ec2" {
  source = "./modules/compute-ec2"
  count  = (var.use_ec2_compute && var.use_hds_data_stack) ? 1 : 0

  # Wait for the SSM params (and their upstream RDS/ElastiCache) to exist before the
  # instance boots — cloud-init reads them at first boot. module.secrets.parameter_prefix
  # is a plain string, so without this the EC2 can boot before the params are written.
  depends_on = [module.secrets]

  naming_prefix         = local.naming_prefix
  environment           = var.environment
  aws_region            = var.aws_region
  instance_type         = var.ec2_instance_type
  vpc_id                = module.network[0].vpc_id
  subnet_id             = module.network[0].public_subnet_ids[0]
  app_security_group_id = module.network[0].app_security_group_id
  key_name              = var.lightsail_key_pair_name
  ssm_parameter_prefix  = module.secrets.parameter_prefix
  ecr_registry          = module.registry.registry_url
  fqdn                  = local.fqdn
  backend_image_tag     = var.backend_image_tag
  biocompute_image_tag  = var.biocompute_image_tag
  frontend_image_tag    = var.frontend_image_tag
  use_ssm_image_tags    = var.use_ssm_image_tags
  tags                  = local.base_tags
}

# Managed Redis (ElastiCache) — FR5. Private subnets + data SG; CMK-encrypted.
module "cache_redis" {
  source = "./modules/cache-redis"
  count  = var.use_hds_data_stack ? 1 : 0

  naming_prefix          = local.naming_prefix
  environment            = var.environment
  subnet_ids             = module.network[0].private_subnet_ids
  vpc_security_group_ids = [module.network[0].data_security_group_id]
  kms_key_arn            = module.kms.key_arn
  num_cache_clusters     = var.redis_num_cache_clusters
  tags                   = local.base_tags
}

# ---------------- Compute (Lightsail) ----------------

module "compute" {
  source = "./modules/compute"
  count  = var.use_legacy_stack ? 1 : 0

  naming_prefix     = local.naming_prefix
  environment       = var.environment
  aws_region        = var.aws_region
  availability_zone = var.lightsail_availability_zone
  blueprint_id      = var.lightsail_blueprint_id
  bundle_id         = var.lightsail_bundle_id
  key_pair_name     = var.lightsail_key_pair_name
  fqdn              = local.fqdn

  ssm_parameter_prefix = module.secrets.parameter_prefix
  ssm_iam_role_arn     = module.secrets.lightsail_iam_role_arn
  ecr_registry         = module.registry.registry_url
  ecr_pull_role_arn    = module.registry.pull_role_arn

  backend_image_tag    = var.backend_image_tag
  biocompute_image_tag = var.biocompute_image_tag
  frontend_image_tag   = var.frontend_image_tag
  use_ssm_image_tags   = var.use_ssm_image_tags

  # When CloudFront fronts the VM, Caddy on the VM serves plain HTTP on :80
  # and stops managing certs. Keep these toggles in lockstep — flipping one
  # without the other breaks the request path.
  behind_proxy = var.use_cloudfront_edge

  tags = local.base_tags

  depends_on = [
    module.secrets,
    module.database_neon,
    module.database_atlas,
  ]
}

# ---------------- DNS (Route 53 — optional) ----------------
# Only created when var.use_route53 = true. Default deployment manages DNS
# manually at the registrar (Microsoft 365) — see providers/aws/README.md §0.4.

module "dns" {
  source = "./modules/dns"
  count  = var.use_route53 ? 1 : 0

  domain      = var.domain
  fqdn        = local.fqdn
  static_ip   = try(module.compute[0].static_ip, try(module.compute_ec2[0].public_ip, null))
  environment = var.environment
}

# ---------------- Edge (CloudFront + ACM) — optional ----------------
# Only created when var.use_cloudfront_edge = true. See `variable
# use_cloudfront_edge` in variables.tf for the why and the operator
# checklist for the two manual DNS records.

module "edge" {
  source = "./modules/edge"
  count  = var.use_cloudfront_edge ? 1 : 0

  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }

  fqdn       = local.fqdn
  origin_ip  = try(module.compute[0].static_ip, try(module.compute_ec2[0].public_ip, null))
  aws_region = var.aws_region
  tags       = local.base_tags
}
