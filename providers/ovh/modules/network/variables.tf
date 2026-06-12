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

variable "data_ports" {
  type    = list(number)
  default = [5432, 27017, 6379, 5672]
}

variable "tags" {
  type    = list(string)
  default = []
}
