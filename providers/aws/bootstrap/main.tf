# One-time bootstrap: creates the S3 state bucket + DynamoDB lock table for EVERY
# environment in one local-state apply. Run once per AWS account before initializing
# any environment's root.
#
# Usage:
#   cd providers/aws/bootstrap
#   terraform init
#   terraform apply                       # creates all of var.environments at once
#   # add an env later: edit var.environments (or -var), re-apply — never destroys others.
#
# Then, per environment, in providers/aws/:
#   terraform init -backend-config=environments/<env>/backend.hcl
#
# This module uses for_each keyed by environment, so each env's bucket/table is an
# independent resource — changing the set never replaces another env's state bucket
# (the old single-resource design did: switching `environment` renamed the one bucket
# = destroy + create). State here is intentionally local and disposable.

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
  }
}

variable "environments" {
  description = "Environments to provision state backends for. \"shared\" holds account-shared resources (e.g. ECR) owned by no single per-environment state (FR8/AC8)."
  type        = set(string)
  default     = ["dev", "staging", "production", "shared"]
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
  for_each = var.environments
  bucket   = "${var.project_name}-${each.key}-tfstate"

  tags = {
    Project     = var.project_name
    Environment = each.key
    Purpose     = "terraform-state"
    ManagedBy   = "terraform-bootstrap"
  }
}

resource "aws_s3_bucket_versioning" "tfstate" {
  for_each = var.environments
  bucket   = aws_s3_bucket.tfstate[each.key].id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  for_each = var.environments
  bucket   = aws_s3_bucket.tfstate[each.key].id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  for_each                = var.environments
  bucket                  = aws_s3_bucket.tfstate[each.key].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_dynamodb_table" "tflock" {
  for_each     = var.environments
  name         = "${var.project_name}-${each.key}-tflock"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  tags = {
    Project     = var.project_name
    Environment = each.key
    Purpose     = "terraform-lock"
  }
}

output "state_buckets" {
  value = { for e in var.environments : e => aws_s3_bucket.tfstate[e].id }
}

output "lock_tables" {
  value = { for e in var.environments : e => aws_dynamodb_table.tflock[e].name }
}
