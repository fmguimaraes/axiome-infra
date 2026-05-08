variable "naming_prefix" {
  type = string
}

variable "environment" {
  type = string
}

variable "org_id" {
  type = string
}

variable "cluster_tier" {
  type    = string
  default = "M0"
}

variable "cloud_provider" {
  type    = string
  default = "AWS"
}

variable "region" {
  type    = string
  default = "EU_CENTRAL_1"
}

variable "mongo_version" {
  type    = string
  default = "7.0"
}
