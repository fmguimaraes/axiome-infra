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
  type    = number
  default = 300
}
