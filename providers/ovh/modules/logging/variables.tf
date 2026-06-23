variable "naming_prefix" {
  type = string
}

variable "environment" {
  type = string
}

variable "ovh_region" {
  description = "HDS French region (GRA*/SBG*/RBX*) — logs stay in-region per CONTRACT §1."
  type        = string
  default     = "GRA11"
}

variable "ovh_ldp_service_name" {
  description = "OVH Logs Data Platform (dbaas_logs) service name. Empty until LDP is provisioned."
  type        = string
  default     = ""
}

variable "ldp_retention_id" {
  description = "LDP retention policy id (in-region). Empty until LDP is provisioned."
  type        = string
  default     = ""
}

variable "tags" {
  type    = list(string)
  default = []
}
