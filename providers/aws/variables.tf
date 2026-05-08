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

variable "domain" {
  description = "Base domain for the platform (e.g., axiome.example.com). Required for Route 53 records and Caddy TLS."
  type        = string
}

variable "subdomain" {
  description = "Environment subdomain prefix. dev -> dev.<domain>, prod -> <domain>"
  type        = string
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
  description = "Idle seconds before Neon autosuspends. 0 = never (paid tier only). Free tier minimum ~300."
  type        = number
  default     = 300
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
