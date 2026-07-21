variable "naming_prefix" {
  description = "Resource naming prefix (e.g., axiome-production)"
  type        = string
}

variable "environment" {
  description = "Deployment environment (dev, staging, production)"
  type        = string

  validation {
    condition     = contains(["dev", "staging", "production"], var.environment)
    error_message = "Environment must be one of: dev, staging, production."
  }
}

variable "data_cmk_arn" {
  description = "ARN of the KMS CMK used for snapshot encryption at rest (NFR4/NFR5)"
  type        = string
}

variable "dlm_target_tag_value" {
  description = "Value of the 'DlmPolicy' tag on the EC2 instance that DLM targets"
  type        = string
  default     = "daily-root"
}

variable "snapshot_schedule" {
  description = "Cron-like schedule for DLM snapshot creation (UTC). Default: daily at 02:00."
  type        = string
  default     = "cron(0 2 * * ? *)"
}

variable "snapshot_retain_count" {
  description = "Number of daily snapshots to retain (rolling). Increase for longer recovery window."
  type        = number
  default     = 7
}

variable "copy_tags" {
  description = "Whether to copy instance/volume tags onto the snapshot"
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags applied to the DLM policy and IAM role"
  type        = map(string)
  default     = {}
}
