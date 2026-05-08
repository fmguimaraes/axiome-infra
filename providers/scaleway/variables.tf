variable "environment" {
  description = "Deployment environment (dev, staging, production)"
  type        = string
  validation {
    condition     = contains(["dev", "staging", "production"], var.environment)
    error_message = "Environment must be one of: dev, staging, production."
  }
}

variable "project_name" {
  type    = string
  default = "axiome"
}

variable "scaleway_region" {
  type    = string
  default = "fr-par"
}

variable "scaleway_zone" {
  type    = string
  default = "fr-par-1"
}

variable "domain" {
  description = "Base domain for the platform (must already be a Scaleway-managed DNS zone)"
  type        = string
}

variable "subdomain" {
  description = "Environment subdomain prefix"
  type        = string
}

# ---------------- Compute (Scaleway Instance) ----------------

variable "instance_type" {
  description = "Scaleway instance type. PLAY2-NANO=tiny, PLAY2-PICO=small ARM, DEV1-S=basic, DEV1-M=medium."
  type        = string
  default     = "PLAY2-PICO"
}

variable "instance_image" {
  description = "Scaleway image. ubuntu_jammy = 22.04."
  type        = string
  default     = "ubuntu_jammy"
}

variable "instance_root_volume_size_gb" {
  type    = number
  default = 40
}

# ---------------- Neon ----------------

variable "neon_project_region_id" {
  type    = string
  default = "aws-eu-central-1"
}

variable "neon_compute_min_cu" {
  type    = number
  default = 0.25
}

variable "neon_compute_max_cu" {
  type    = number
  default = 0.25
}

variable "neon_autosuspend_seconds" {
  type    = number
  default = 300
}

# ---------------- Atlas ----------------

variable "atlas_org_id" {
  type = string
}

variable "atlas_cluster_tier" {
  type    = string
  default = "M0"
}

variable "atlas_cloud_provider" {
  type    = string
  default = "AWS"
}

variable "atlas_region" {
  type    = string
  default = "EU_CENTRAL_1"
}

variable "atlas_mongo_version" {
  type    = string
  default = "7.0"
}

# ---------------- Image tags ----------------

variable "backend_image_tag" {
  type    = string
  default = "latest"
}

variable "biocompute_image_tag" {
  type    = string
  default = "latest"
}

variable "frontend_image_tag" {
  type    = string
  default = "latest"
}

variable "tags" {
  type    = list(string)
  default = []
}
