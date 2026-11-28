variable "naming_prefix" {
  description = "Resource name prefix. The bucket is named <naming_prefix>-knowledge-store and the IAM user <naming_prefix>-knowledge-tooling. Account-shared — pass the bare project name (e.g. \"axiome\"), never a per-environment prefix."
  type        = string
}

variable "kms_key_arn" {
  description = "CMK ARN for S3 SSE-KMS. Empty (default) = SSE-S3 (AES256), matching modules/storage and modules/tenant when no platform CMK is wired to this bucket."
  type        = string
  default     = ""
}

variable "tags" {
  type    = map(string)
  default = {}
}
