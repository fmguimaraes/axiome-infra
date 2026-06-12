variable "naming_prefix" {
  type = string
}

variable "environment" {
  type = string
}

variable "ovh_region" {
  type    = string
  default = "GRA11"
}

variable "tags" {
  type    = list(string)
  default = []
}
