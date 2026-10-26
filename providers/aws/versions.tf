terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
    neon = {
      source  = "kislerdm/neon"
      version = ">= 0.6, < 0.16" # 0.16+ dropped neon_project.default_endpoint_settings
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}
