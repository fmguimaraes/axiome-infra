variable "naming_prefix" {
  type = string
}

variable "environment" {
  type = string
}

variable "scaleway_region" {
  type    = string
  default = "fr-par"
}

variable "secrets" {
  description = "Map of runtime config key -> secret value. Stored one secret per key."
  type        = map(string)
  default     = {}
  sensitive   = true
}

variable "tags" {
  type    = list(string)
  default = []
}
