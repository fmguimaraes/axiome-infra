variable "naming_prefix" {
  type = string
}

variable "environment" {
  type = string
}

variable "aws_region" {
  type = string
}

variable "availability_zone" {
  type = string
}

variable "blueprint_id" {
  type = string
}

variable "bundle_id" {
  type = string
}

variable "fqdn" {
  type = string
}

variable "ssm_parameter_prefix" {
  type = string
}

variable "ssm_iam_role_arn" {
  type = string
}

variable "ecr_registry" {
  type = string
}

variable "ecr_pull_role_arn" {
  type = string
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
  type    = map(string)
  default = {}
}

variable "key_pair_name" {
  description = "Lightsail keypair to inject as authorized_keys. Must already exist in the same region (create via Lightsail console or aws_lightsail_key_pair). Default null = use Lightsail's built-in default key, which can drift if rotated in the console."
  type        = string
  default     = null
  nullable    = true
}
