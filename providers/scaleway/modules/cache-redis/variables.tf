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

variable "node_type" {
  type    = string
  default = "RED1-micro"
}

variable "private_network_id" {
  type    = string
  default = null
}

variable "tags" {
  type    = list(string)
  default = []
}
