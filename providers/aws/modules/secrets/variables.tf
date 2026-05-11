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
  type      = string
  sensitive = true
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
