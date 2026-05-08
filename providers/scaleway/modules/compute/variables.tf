variable "naming_prefix" {
  type = string
}

variable "environment" {
  type = string
}

variable "zone" {
  type = string
}

variable "region" {
  type = string
}

variable "instance_type" {
  type = string
}

variable "instance_image" {
  type = string
}

variable "root_volume_size_gb" {
  type    = number
  default = 40
}

variable "fqdn" {
  type = string
}

variable "registry_endpoint" {
  type = string
}

variable "registry_credentials" {
  type      = string
  sensitive = true
}

variable "postgres_url" {
  type      = string
  sensitive = true
}

variable "mongodb_url" {
  type      = string
  sensitive = true
}

variable "s3_endpoint" {
  type = string
}

variable "s3_region" {
  type = string
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

variable "s3_access_key" {
  type      = string
  sensitive = true
}

variable "s3_secret_key" {
  type      = string
  sensitive = true
}

variable "backend_image_tag" {
  type = string
}

variable "biocompute_image_tag" {
  type = string
}

variable "frontend_image_tag" {
  type = string
}

variable "tags" {
  type    = list(string)
  default = []
}
