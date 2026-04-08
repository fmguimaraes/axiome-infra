variable "naming_prefix" {
  description = "Naming prefix for resources"
  type        = string
}

variable "region" {
  description = "Cloud region"
  type        = string
}

variable "zone" {
  description = "Cloud zone"
  type        = string
}

variable "tags" {
  description = "Tags to apply to resources"
  type        = list(string)
  default     = []
}
