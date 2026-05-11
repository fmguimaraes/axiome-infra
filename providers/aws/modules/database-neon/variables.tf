variable "naming_prefix" {
  type = string
}

variable "environment" {
  type = string
}

variable "region_id" {
  type = string
}

variable "compute_min_cu" {
  type    = number
  default = 0.25
}

variable "compute_max_cu" {
  type    = number
  default = 0.25
}

variable "autosuspend_seconds" {
  description = "Idle seconds before Neon suspends compute. Set to null on Free tier (the API rejects modifying this attribute). Set to 0 to disable suspend (paid plans only)."
  type        = number
  default     = null
  nullable    = true
}

variable "history_retention_seconds" {
  description = "PITR / branch history retention. Free tier max is 21600 (6h). Launch supports up to 7 days; Scale up to 30 days."
  type        = number
  default     = 21600
}
