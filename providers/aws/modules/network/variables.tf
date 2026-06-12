variable "naming_prefix" {
  type = string
}

variable "environment" {
  type = string
}

variable "vpc_cidr" {
  type    = string
  default = "10.20.0.0/16"
}

variable "availability_zones" {
  description = "HDS-certified French AZs (eu-west-3)."
  type        = list(string)
  default     = ["eu-west-3a", "eu-west-3b"]
}

variable "app_ports" {
  description = "Service ports the app tier accepts from the edge SG."
  type        = list(number)
  default     = [80, 3000, 3002, 3003, 3004, 8000]
}

variable "data_ports" {
  description = "Data-tier ports reachable ONLY from the app SG (Postgres, Mongo, Redis, RabbitMQ)."
  type        = list(number)
  default     = [5432, 27017, 6379, 5672]
}

variable "tags" {
  type    = map(string)
  default = {}
}
