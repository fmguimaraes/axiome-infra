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

variable "behind_proxy" {
  description = <<-EOT
    When true, Caddy on the VM serves plain HTTP on :80 with auto_https off,
    expecting an upstream TLS terminator (CloudFront via the edge module).
    When false (default), Caddy listens on :443 and manages its own LE certs
    for var.fqdn. Switching to true also strips the proxy auth/proto header
    injection — CloudFront handles those.
  EOT
  type        = bool
  default     = false
}

variable "use_ssm_image_tags" {
  description = <<-EOT
    If true, image tags are stored in SSM Parameter Store and read by the VM at boot
    via aws ssm get-parameters-by-path. Out-of-band tag updates (via the deploy
    workflow) no longer change user_data, so the Lightsail instance is NOT recreated
    on image bumps — deploys become a `docker compose pull && up -d` over SSH.

    If false (legacy), image tags are templated into the cloud-init user_data, so
    every tag bump changes user_data_hash and forces a destroy/create of the VM.

    Default false to preserve existing staging/production behavior; flip to true on
    a per-environment basis once SSH + SSM deploy plumbing is in place for that env.
  EOT
  type        = bool
  default     = false
}
