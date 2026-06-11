# Common contract variables (see providers/CONTRACT.md §2). Names/semantics MUST
# match the aws and scaleway roots. OVH-specific sizing/identity vars are additive.

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

variable "domain" {
  description = "Base domain for the platform (a DNS zone managed via Terraform)"
  type        = string
}

variable "subdomain" {
  description = "Environment subdomain prefix (e.g. aphm-mipp)"
  type        = string
}

# ---------------- OVH region / project (HDS-certified French region — CONTRACT §1) ----------------

variable "ovh_endpoint" {
  description = "OVH API endpoint (ovh-eu for the EU region)."
  type        = string
  default     = "ovh-eu"
}

variable "ovh_region" {
  description = "OVH Public Cloud region. MUST be HDS-certified French: GRA*, SBG*, RBX*."
  type        = string
  default     = "GRA11"
  validation {
    condition     = can(regex("^(GRA|SBG|RBX)", var.ovh_region))
    error_message = "ovh_region must be a French region (GRA*, SBG*, RBX*) per the sovereignty contract."
  }
}

variable "ovh_s3_region" {
  description = "OVH Object Storage (S3-compatible) region code, lower-case (e.g. gra, sbg, rbx)."
  type        = string
  default     = "gra"
}

variable "ovh_cloud_project_id" {
  description = "OVH Public Cloud project (service name) hosting compute/storage/network."
  type        = string
  default     = ""
}

# ---------------- Compute (OVH Public Cloud instance) ----------------

variable "ovh_instance_flavor" {
  description = "OVH Public Cloud flavor. b3-8 = 2 vCPU / 8 GB; b3-16 = 4 vCPU / 16 GB."
  type        = string
  default     = "b3-8"
}

variable "ovh_instance_image" {
  description = "OVH instance image name (e.g. Ubuntu 22.04)."
  type        = string
  default     = "Ubuntu 22.04"
}

variable "ovh_instance_root_volume_size_gb" {
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
  type    = string
  default = ""
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
