variable "environment" {
  description = "Deployment environment (dev, staging, production)"
  type        = string
  validation {
    condition     = contains(["dev", "staging", "production"], var.environment)
    error_message = "Environment must be one of: dev, staging, production."
  }
}

variable "provider_name" {
  description = "Cloud provider to use (scaleway, aws)"
  type        = string
  default     = "scaleway"
  validation {
    condition     = contains(["scaleway", "aws"], var.provider_name)
    error_message = "Provider must be one of: scaleway, aws."
  }
}

variable "region" {
  description = "Cloud region for deployment"
  type        = string
  default     = "fr-par"
}

variable "zone" {
  description = "Cloud zone within region"
  type        = string
  default     = "fr-par-1"
}

variable "project_name" {
  description = "Project name used for resource naming"
  type        = string
  default     = "axiome"
}

variable "domain" {
  description = "Base domain for the platform"
  type        = string
  default     = ""
}

variable "vpc_cidr" {
  description = "CIDR block for the private network"
  type        = string
  default     = "10.0.0.0/16"
}

# Database sizing
variable "postgres_node_type" {
  description = "Scaleway managed database node type for Postgres"
  type        = string
  default     = "DB-DEV-S"
}

variable "mongodb_node_type" {
  description = "Scaleway managed database node type for MongoDB"
  type        = string
  default     = "MGDB-PLAY2-NANO"
}

# Compute sizing
variable "backend_min_scale" {
  description = "Minimum number of backend container instances"
  type        = number
  default     = 1
}

variable "backend_max_scale" {
  description = "Maximum number of backend container instances"
  type        = number
  default     = 2
}

variable "backend_cpu_limit" {
  description = "CPU limit for backend container (in mVCPU)"
  type        = number
  default     = 1000
}

variable "backend_memory_limit" {
  description = "Memory limit for backend container (in MB)"
  type        = number
  default     = 1024
}

variable "biocompute_min_scale" {
  description = "Minimum number of biocompute container instances"
  type        = number
  default     = 1
}

variable "biocompute_max_scale" {
  description = "Maximum number of biocompute container instances"
  type        = number
  default     = 2
}

variable "biocompute_cpu_limit" {
  description = "CPU limit for biocompute container (in mVCPU)"
  type        = number
  default     = 2000
}

variable "biocompute_memory_limit" {
  description = "Memory limit for biocompute container (in MB)"
  type        = number
  default     = 2048
}

# Feature flags
variable "enable_monitoring" {
  description = "Enable Scaleway Cockpit monitoring integration"
  type        = bool
  default     = true
}

variable "enable_frontend_container" {
  description = "Deploy frontend as container (false = static hosting on object storage)"
  type        = bool
  default     = false
}

# Tags
variable "tags" {
  description = "Additional tags to apply to all resources"
  type        = list(string)
  default     = []
}
