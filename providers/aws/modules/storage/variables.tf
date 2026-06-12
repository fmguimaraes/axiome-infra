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
  description = "CMK ARN for S3 SSE-KMS (FR6). Empty = fall back to SSE-S3 (AES256)."
  type        = string
  default     = ""
}
