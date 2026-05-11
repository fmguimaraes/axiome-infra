variable "environment" {
  description = "Deployment environment (dev, staging, production)"
  type        = string
  validation {
    condition     = contains(["dev", "staging", "production"], var.environment)
    error_message = "Environment must be one of: dev, staging, production."
  }
}

variable "project_name" {
  description = "Project name used for resource naming"
  type        = string
  default     = "axiome"
}

variable "aws_region" {
  description = "AWS region for compute, storage, and registry"
  type        = string
  default     = "eu-west-3"
}

variable "create_ecr_repositories" {
  description = "Whether this env's apply manages the ECR repositories. ECR repos are account-level shared across envs, so exactly one env should own them. Default null = use the legacy rule (production owns)."
  type        = bool
  default     = null
  nullable    = true
}

variable "domain" {
  description = "Base domain for the platform (e.g., axiome.example.com). Required for Route 53 records and Caddy TLS."
  type        = string
}

variable "subdomain" {
  description = "Environment subdomain prefix. dev -> dev.<domain>, prod -> <domain>"
  type        = string
}

variable "use_route53" {
  description = "If true, manage the env A record in a pre-existing Route 53 hosted zone for var.domain. If false (default), DNS is configured manually at the domain registrar (e.g., Hostinger) — Terraform only provisions the Lightsail static IP and exposes it via the lightsail_static_ip output."
  type        = bool
  default     = false
}

# ---------------- Lightsail compute ----------------

variable "lightsail_blueprint_id" {
  description = "Lightsail OS image. ubuntu_22_04 supports docker via cloud-init."
  type        = string
  default     = "ubuntu_22_04"
}

variable "lightsail_bundle_id" {
  description = "Lightsail bundle (sizing). nano_3_0=$5, micro_3_0=$10, small_3_0=$20 (x86), or arm equivalents (small_arm_3_0=$12 with 4GB)."
  type        = string
  default     = "small_arm_3_0"
}

variable "lightsail_availability_zone" {
  description = "Lightsail AZ within the region (e.g., eu-west-3a)."
  type        = string
  default     = "eu-west-3a"
}

variable "lightsail_key_pair_name" {
  description = "Lightsail keypair name to authorize on the VM. Must already exist in the same region. Set null to use Lightsail's built-in default key (fragile — drifts when rotated in console)."
  type        = string
  default     = null
  nullable    = true
}

# ---------------- Neon (Postgres) ----------------

variable "neon_project_region_id" {
  description = "Neon region. EU options: aws-eu-central-1 (Frankfurt), aws-eu-west-2 (London)."
  type        = string
  default     = "aws-eu-central-1"
}

variable "neon_compute_min_cu" {
  description = "Neon minimum compute units (free tier = 0.25)."
  type        = number
  default     = 0.25
}

variable "neon_compute_max_cu" {
  description = "Neon maximum compute units."
  type        = number
  default     = 0.25
}

variable "neon_autosuspend_seconds" {
  description = "Idle seconds before Neon autosuspends. Set null on Free tier (the API rejects any value). 0 = never suspend (paid plans only)."
  type        = number
  default     = null
  nullable    = true
}

variable "neon_history_retention_seconds" {
  description = "PITR / branch history retention. Free tier max is 21600 (6h). Launch up to 7d, Scale up to 30d."
  type        = number
  default     = 21600
}

# ---------------- Atlas (MongoDB) ----------------

variable "atlas_org_id" {
  description = "MongoDB Atlas organization ID. Sourced from console; one Atlas org covers all environments."
  type        = string
}

variable "atlas_cluster_tier" {
  description = "Atlas cluster tier. M0 (free), M2/M5 (shared), M10+ (dedicated)."
  type        = string
  default     = "M0"
}

variable "atlas_cloud_provider" {
  description = "Atlas underlying cloud provider."
  type        = string
  default     = "AWS"
}

variable "atlas_region" {
  description = "Atlas region (Atlas naming, e.g., EU_CENTRAL_1 = Frankfurt)."
  type        = string
  default     = "EU_CENTRAL_1"
}

variable "atlas_mongo_version" {
  description = "MongoDB major version."
  type        = string
  default     = "7.0"
}

# ---------------- Application image tags ----------------

variable "backend_image_tag" {
  description = "Docker image tag for backend"
  type        = string
  default     = "latest"
}

variable "biocompute_image_tag" {
  description = "Docker image tag for biocompute"
  type        = string
  default     = "latest"
}

variable "frontend_image_tag" {
  description = "Docker image tag for frontend"
  type        = string
  default     = "latest"
}

# ---------------- Tags ----------------

variable "common_tags" {
  description = "Tags applied to all taggable AWS resources"
  type        = map(string)
  default     = {}
}
