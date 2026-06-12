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

variable "ovh_cloud_project_id" {
  type    = string
  default = ""
}

variable "private_network_id" {
  type    = string
  default = null
}

variable "tags" {
  type    = list(string)
  default = []
}
