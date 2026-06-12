variable "naming_prefix" {
  type = string
}

variable "environment" {
  type = string
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "enable_key_rotation" {
  type    = bool
  default = true
}
