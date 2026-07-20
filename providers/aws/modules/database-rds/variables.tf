variable "naming_prefix" {
  type = string
}

variable "environment" {
  type = string
}

variable "db_name" {
  description = "Initial database; service schemas user_svc / organization_svc live inside it."
  type        = string
  default     = "axiome"
}

variable "username" {
  description = "RDS master user. Admin/migration use only — never handed to application containers (FR10/NFR2; see app_runtime_username)."
  type        = string
  default     = "axiome"
}

variable "app_runtime_username" {
  description = "Least-privilege Postgres role for application runtime traffic (user-service, organization-service, bio-compute), scoped to the pilot tenant's own schemas only — no CREATE/DROP, no superuser, no cross-schema access (FR10/NFR2/AC8). Distinct from `username` (RDS master). Terraform only generates this role's password; the role itself is created by db/01_pilot_tenant_app_role.sql (no `postgresql` provider is configured in this repo — see CONTRACT.md)."
  type        = string
  default     = "axiome_app"
}

variable "engine_version" {
  type    = string
  default = "16"
}

variable "instance_class" {
  type    = string
  default = "db.t3.micro"
}

variable "allocated_storage" {
  type    = number
  default = 20
}

variable "max_allocated_storage" {
  type    = number
  default = 100
}

variable "kms_key_arn" {
  description = "CMK for storage encryption at rest (FR6)."
  type        = string
}

variable "subnet_ids" {
  description = "Private subnet IDs (data tier) from the network module."
  type        = list(string)
}

variable "vpc_security_group_ids" {
  description = "Data-tier security group (ingress from app SG only — NFR7)."
  type        = list(string)
}

variable "multi_az" {
  type    = bool
  default = false
}

variable "backup_retention_days" {
  type    = number
  default = 7
}

variable "tags" {
  type    = map(string)
  default = {}
}
