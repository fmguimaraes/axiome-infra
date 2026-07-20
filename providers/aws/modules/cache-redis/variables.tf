variable "naming_prefix" {
  type = string
}

variable "environment" {
  type = string
}

variable "node_type" {
  description = "ElastiCache node type. cache.t3.micro for the pilot."
  type        = string
  default     = "cache.t3.micro"
}

variable "engine_version" {
  type    = string
  default = "7.1"
}

variable "parameter_group_name" {
  type    = string
  default = "default.redis7"
}

variable "num_cache_clusters" {
  description = "1 = single node (pilot); >1 enables automatic failover + Multi-AZ."
  type        = number
  default     = 1
}

variable "subnet_ids" {
  description = "Private subnet IDs (data tier) from the network module."
  type        = list(string)
}

variable "vpc_security_group_ids" {
  description = "Data-tier SG (ingress from app SG only — NFR7)."
  type        = list(string)
}

variable "kms_key_arn" {
  description = "CMK for at-rest encryption (FR6)."
  type        = string
}

variable "snapshot_retention_days" {
  description = "Automated daily ElastiCache snapshot retention (FR1/NFR1). 0 disables backups."
  type        = number
  default     = 7
}

variable "snapshot_window" {
  description = "Daily UTC window for the automated snapshot (FR1), outside business hours."
  type        = string
  default     = "03:00-04:00"
}

variable "tags" {
  type    = map(string)
  default = {}
}
