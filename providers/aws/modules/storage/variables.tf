variable "naming_prefix" {
  type = string
}

variable "environment" {
  type = string
}

variable "cors_allowed_origins" {
  description = "App origins allowed to PUT/GET the uploads bucket from the browser (presigned URLs). Empty disables CORS."
  type        = list(string)
  default     = []
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
