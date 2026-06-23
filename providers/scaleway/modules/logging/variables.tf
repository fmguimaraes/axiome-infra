variable "naming_prefix" {
  type = string
}

variable "scaleway_region" {
  description = "Cockpit region. Must be the HDS French region (fr-par) per CONTRACT §1."
  type        = string
}

variable "log_retention_days" {
  description = "Cockpit logs retention. Scaleway accepts 1, 7, 14, 30, 90, 180, 365 days."
  type        = number
  default     = 30
}
