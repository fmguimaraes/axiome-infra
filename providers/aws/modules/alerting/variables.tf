variable "naming_prefix" {
  type = string
}

variable "environment" {
  type = string
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "kms_key_arn" {
  description = "CMK (in var.aws_region) encrypting the alerts SNS topic at rest (NFR4)."
  type        = string
}

variable "alert_email" {
  description = "Email address subscribed to the alerts SNS topic(s). Empty = no email subscription — still fires to SNS/CloudWatch; subscribe manually or via another protocol (Slack/PagerDuty/Opsgenie SNS integration, SMS, etc)."
  type        = string
  default     = ""
}

variable "disk_threshold_percent" {
  description = "EC2 root-volume disk_used_percent threshold that pages on-call (FR12)."
  type        = number
  default     = 85
}

variable "ec2_instance_id" {
  description = "EC2 instance ID to alarm on (disk, status checks). Empty = skip EC2 alarms."
  type        = string
  default     = ""
}

variable "rds_instance_id" {
  description = "RDS instance identifier to alarm on (storage, automated-backup failure). Empty = skip RDS alarms."
  type        = string
  default     = ""
}

variable "redis_replication_group_id" {
  description = "ElastiCache replication group ID to alarm on. Empty = skip ElastiCache alarms."
  type        = string
  default     = ""
}

variable "acm_certificate_arn" {
  description = "ACM certificate ARN (us-east-1, from modules/edge) to alarm on approaching-expiry events. Empty = skip — envs that terminate TLS via Caddy/Let's Encrypt instead (no ACM cert) get TLS-cert-expiry coverage from the portable Prometheus blackbox_exporter probe (observability/alerts.yml)."
  type        = string
  default     = ""
}
