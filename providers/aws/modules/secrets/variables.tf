variable "naming_prefix" {
  type = string
}

variable "environment" {
  type = string
}

variable "postgres_url" {
  description = "Master/admin Postgres connection string. Retained as a fallback for the legacy Neon path (no scoped runtime role exists there); superseded by postgres_app_url whenever that is set (FR10/NFR2)."
  type        = string
  sensitive   = true
}

variable "postgres_app_url" {
  description = "Least-privilege pilot-tenant Postgres connection string (module.database_rds.app_runtime_connection_string) — what DATABASE_URL / USER_DATABASE_URL / ORGANIZATION_DATABASE_URL actually publish when set (FR10/NFR2/AC8). Empty falls back to postgres_url (master) — only expected on the legacy Neon path, which predates the pilot-tenant role."
  type        = string
  default     = ""
  sensitive   = true
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

variable "mailjet_api_key" {
  description = "Mailjet API key for transactional email (user-service EmailService). Empty disables sending; the service falls back to logging links."
  type        = string
  default     = ""
  sensitive   = true
}

variable "mailjet_secret_key" {
  description = "Mailjet secret key, paired with mailjet_api_key."
  type        = string
  default     = ""
  sensitive   = true
}

variable "mailjet_from_email" {
  description = "Verified Mailjet sender address used as the From of all platform emails."
  type        = string
  default     = "contact@axiomebio.com"
}

variable "mailjet_from_name" {
  description = "Display name shown on the From of all platform emails."
  type        = string
  default     = "Axiome"
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "create_lightsail_iam" {
  type        = bool
  default     = true
  description = "Create the Lightsail SSM-read IAM role. Only needed for the legacy Lightsail compute path; the EC2/HDS stack uses its own instance profile."
}
