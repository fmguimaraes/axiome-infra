variable "naming_prefix" {
  type = string
}

variable "environment" {
  type = string
}

variable "postgres_url" {
  type      = string
  sensitive = true
}

variable "mongodb_url" {
  description = "External Mongo URL (Atlas). Used when use_inregion_mongo = false."
  type        = string
  default     = ""
  sensitive   = true
}

variable "use_inregion_mongo" {
  description = "When true, MONGODB_URL targets the in-region self-hosted Mongo container (built from a generated root password), not var.mongodb_url (Atlas) — FR3."
  type        = bool
  default     = false
}

variable "redis_url" {
  description = "REDIS_URL for the app (e.g. ElastiCache rediss://...). Published to SSM only when publish_redis_url = true."
  type        = string
  default     = ""
  sensitive   = true
}

variable "publish_redis_url" {
  description = "Whether to publish REDIS_URL to SSM (plan-time bool; the value itself is known only after apply). True for the ElastiCache path."
  type        = bool
  default     = false
}

variable "s3_artifacts_bucket" {
  type = string
}

variable "s3_uploads_bucket" {
  type = string
}

variable "s3_system_bucket" {
  type = string
}

variable "s3_region" {
  type = string
}

variable "ecr_registry" {
  type = string
}

variable "domain" {
  type = string
}

variable "fqdn" {
  description = "Full qualified domain for this env, used as the default CORS origin (e.g., dev.axiomebio.com)."
  type        = string
}

variable "tags" {
  type    = map(string)
  default = {}
}
