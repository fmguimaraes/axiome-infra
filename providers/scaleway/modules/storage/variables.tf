variable "naming_prefix" {
  type = string
}

variable "region" {
  type = string
}

variable "environment" {
  type = string
}

variable "tags" {
  type    = list(string)
  default = []
}
