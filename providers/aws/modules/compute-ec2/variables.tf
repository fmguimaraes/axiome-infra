variable "naming_prefix" {
  type = string
}

variable "environment" {
  type = string
}

variable "aws_region" {
  type = string
}

variable "instance_type" {
  description = "EC2 instance type. t3.medium = 2 vCPU / 4 GB for the pilot stack."
  type        = string
  default     = "t3.medium"
}

variable "vpc_id" {
  type = string
}

variable "subnet_id" {
  description = "Public subnet to launch the instance in (edge/app single-VM)."
  type        = string
}

variable "app_security_group_id" {
  description = "Network app SG — attached so the data SG (which allows the app SG) permits this VM to reach RDS."
  type        = string
}

variable "root_volume_size_gb" {
  type    = number
  default = 40
}

variable "key_name" {
  description = "Existing EC2 key pair for SSH. null = no SSH key (SSM/console only)."
  type        = string
  default     = null
  nullable    = true
}

variable "ssm_parameter_prefix" {
  type = string
}

variable "ecr_registry" {
  type = string
}

variable "fqdn" {
  type = string
}

variable "backend_image_tag" {
  type    = string
  default = "latest"
}

variable "biocompute_image_tag" {
  type    = string
  default = "latest"
}

variable "frontend_image_tag" {
  type    = string
  default = "latest"
}

variable "use_ssm_image_tags" {
  type    = bool
  default = true
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention for the EC2 log group. Logs stay in-region (eu-west-3) per CONTRACT §1."
  type        = number
  default     = 30
}

variable "tags" {
  type    = map(string)
  default = {}
}
