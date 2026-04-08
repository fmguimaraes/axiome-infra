variable "naming_prefix" {
  description = "Naming prefix for resources"
  type        = string
}

variable "region" {
  description = "Cloud region"
  type        = string
}

variable "postgres_node_type" {
  description = "Scaleway managed database node type for Postgres"
  type        = string
}

variable "mongodb_node_type" {
  description = "Scaleway managed database node type for MongoDB"
  type        = string
}

variable "postgres_volume_size" {
  description = "Postgres volume size in GB"
  type        = number
  default     = 10
}

variable "private_network_id" {
  description = "Private network ID for database connectivity"
  type        = string
}

variable "tags" {
  description = "Tags to apply to resources"
  type        = list(string)
  default     = []
}
