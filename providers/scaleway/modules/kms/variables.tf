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

variable "tags" {
  type    = list(string)
  default = []
}
