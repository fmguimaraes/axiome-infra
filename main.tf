locals {
  common_tags = concat(
    [
      "project:${var.project_name}",
      "environment:${var.environment}",
      "managed-by:terraform",
    ],
    var.tags
  )

  naming_prefix = "${var.project_name}-${var.environment}"
}

provider "scaleway" {
  region = var.region
  zone   = var.zone
}

module "network" {
  source = "./modules/network"

  naming_prefix = local.naming_prefix
  region        = var.region
  zone          = var.zone
  tags          = local.common_tags
}

module "registry" {
  source = "./modules/registry"

  naming_prefix = local.naming_prefix
  region        = var.region
  tags          = local.common_tags
}

module "database" {
  source = "./modules/database"

  naming_prefix      = local.naming_prefix
  region             = var.region
  postgres_node_type = var.postgres_node_type
  mongodb_node_type  = var.mongodb_node_type
  private_network_id = module.network.private_network_id
  tags               = local.common_tags
}

module "storage" {
  source = "./modules/storage"

  naming_prefix = local.naming_prefix
  region        = var.region
  tags          = local.common_tags
}

module "secrets" {
  source = "./modules/secrets"

  naming_prefix = local.naming_prefix
  region        = var.region
  tags          = local.common_tags
}

module "compute" {
  source = "./modules/compute"

  naming_prefix             = local.naming_prefix
  region                    = var.region
  registry_endpoint         = module.registry.registry_endpoint
  private_network_id        = module.network.private_network_id
  backend_image_tag         = var.backend_image_tag
  biocompute_image_tag      = var.biocompute_image_tag
  frontend_image_tag        = var.frontend_image_tag
  backend_min_scale         = var.backend_min_scale
  backend_max_scale         = var.backend_max_scale
  backend_cpu_limit         = var.backend_cpu_limit
  backend_memory_limit      = var.backend_memory_limit
  biocompute_min_scale      = var.biocompute_min_scale
  biocompute_max_scale      = var.biocompute_max_scale
  biocompute_cpu_limit      = var.biocompute_cpu_limit
  biocompute_memory_limit   = var.biocompute_memory_limit
  enable_frontend_container = var.enable_frontend_container
  tags                      = local.common_tags
}
