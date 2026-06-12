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

variable "data_ports" {
  type    = list(number)
  default = [5432, 27017, 6379, 5672]
}

variable "tags" {
  type    = list(string)
  default = []
}
