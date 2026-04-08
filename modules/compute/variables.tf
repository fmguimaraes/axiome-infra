variable "naming_prefix" {
  description = "Naming prefix for resources"
  type        = string
}

variable "region" {
  description = "Cloud region"
  type        = string
}

variable "registry_endpoint" {
  description = "Container registry endpoint"
  type        = string
}

variable "private_network_id" {
  description = "Private network ID"
  type        = string
}

variable "backend_min_scale" {
  description = "Minimum backend instances"
  type        = number
}

variable "backend_max_scale" {
  description = "Maximum backend instances"
  type        = number
}

variable "backend_cpu_limit" {
  description = "Backend CPU limit (mVCPU)"
  type        = number
}

variable "backend_memory_limit" {
  description = "Backend memory limit (MB)"
  type        = number
}

variable "biocompute_min_scale" {
  description = "Minimum biocompute instances"
  type        = number
}

variable "biocompute_max_scale" {
  description = "Maximum biocompute instances"
  type        = number
}

variable "biocompute_cpu_limit" {
  description = "Biocompute CPU limit (mVCPU)"
  type        = number
}

variable "biocompute_memory_limit" {
  description = "Biocompute memory limit (MB)"
  type        = number
}

variable "enable_frontend_container" {
  description = "Deploy frontend as container"
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags to apply to resources"
  type        = list(string)
  default     = []
}
