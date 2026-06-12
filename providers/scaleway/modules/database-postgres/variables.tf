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

variable "engine_version" {
  type    = string
  default = "PostgreSQL-16"
}

variable "node_type" {
  type    = string
  default = "DB-DEV-S"
}

variable "private_network_id" {
  type    = string
  default = null
}

variable "tags" {
  type    = list(string)
  default = []
}
