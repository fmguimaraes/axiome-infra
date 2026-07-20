variable "project_name" {
  description = "Project name used for resource naming"
  type        = string
  default     = "axiome"
}

variable "aws_region" {
  description = "AWS region for account-shared resources"
  type        = string
  default     = "eu-west-3"
}

variable "common_tags" {
  description = "Extra tags merged into every resource"
  type        = map(string)
  default     = {}
}
