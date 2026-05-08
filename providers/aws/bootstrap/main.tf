# One-time bootstrap: creates the S3 state bucket and DynamoDB lock table that
# the root Terraform stack uses. Run this with LOCAL state once per AWS account
# before initializing any environment.
#
# Usage:
#   cd providers/aws/bootstrap
#   terraform init
#   terraform apply -var=environment=dev
#   terraform apply -var=environment=staging
#   terraform apply -var=environment=production
#
# After all three are created, return to providers/aws/ and run:
#   terraform init -backend-config=environments/<env>/backend.hcl
#
# State for this bootstrap module itself is intentionally local — losing it is
# not catastrophic (the bucket and table can be imported or recreated).

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
  }
}

variable "environment" {
  description = "Environment name (dev, staging, production)"
  type        = string
}

variable "aws_region" {
  type    = string
  default = "eu-west-3"
}

variable "project_name" {
  type    = string
  default = "axiome"
}

provider "aws" {
  region = var.aws_region
}

resource "aws_s3_bucket" "tfstate" {
  bucket = "${var.project_name}-${var.environment}-tfstate"

  tags = {
    Project     = var.project_name
    Environment = var.environment
    Purpose     = "terraform-state"
    ManagedBy   = "terraform-bootstrap"
  }
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket                  = aws_s3_bucket.tfstate.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_dynamodb_table" "tflock" {
  name         = "${var.project_name}-${var.environment}-tflock"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  tags = {
    Project     = var.project_name
    Environment = var.environment
    Purpose     = "terraform-lock"
  }
}

output "state_bucket" {
  value = aws_s3_bucket.tfstate.id
}

output "lock_table" {
  value = aws_dynamodb_table.tflock.name
}

output "backend_hcl" {
  description = "Drop this into providers/aws/environments/<env>/backend.hcl"
  value = <<-EOT
    bucket         = "${aws_s3_bucket.tfstate.id}"
    key            = "infrastructure/terraform.tfstate"
    region         = "${var.aws_region}"
    dynamodb_table = "${aws_dynamodb_table.tflock.name}"
    encrypt        = true
  EOT
}
