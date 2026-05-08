variable "create_repositories" {
  description = "Whether to create ECR repositories. Only one environment (typically production) should create; others reuse via data."
  type        = bool
  default     = false
}

variable "project_name" {
  type    = string
  default = "axiome"
}

variable "tags" {
  type    = map(string)
  default = {}
}
