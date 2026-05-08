# Runtime configuration written to SSM Parameter Store. The Lightsail VM reads
# these at boot via the IAM role attached below. Free of charge for standard
# parameters.

locals {
  prefix = "/${var.environment}/${var.naming_prefix}"
}

resource "random_password" "jwt_secret" {
  length  = 64
  special = false
}

resource "aws_ssm_parameter" "database_url" {
  name  = "${local.prefix}/DATABASE_URL"
  type  = "SecureString"
  value = var.postgres_url
  tags  = var.tags
}

resource "aws_ssm_parameter" "mongodb_url" {
  name  = "${local.prefix}/MONGODB_URL"
  type  = "SecureString"
  value = var.mongodb_url
  tags  = var.tags
}

resource "aws_ssm_parameter" "s3_region" {
  name  = "${local.prefix}/S3_REGION"
  type  = "String"
  value = var.s3_region
  tags  = var.tags
}

resource "aws_ssm_parameter" "s3_artifacts" {
  name  = "${local.prefix}/S3_BUCKET_ARTIFACTS"
  type  = "String"
  value = var.s3_artifacts_bucket
  tags  = var.tags
}

resource "aws_ssm_parameter" "s3_uploads" {
  name  = "${local.prefix}/S3_BUCKET_UPLOADS"
  type  = "String"
  value = var.s3_uploads_bucket
  tags  = var.tags
}

resource "aws_ssm_parameter" "s3_system" {
  name  = "${local.prefix}/S3_BUCKET_SYSTEM"
  type  = "String"
  value = var.s3_system_bucket
  tags  = var.tags
}

resource "aws_ssm_parameter" "ecr_registry" {
  name  = "${local.prefix}/ECR_REGISTRY"
  type  = "String"
  value = var.ecr_registry
  tags  = var.tags
}

resource "aws_ssm_parameter" "domain" {
  name  = "${local.prefix}/DOMAIN"
  type  = "String"
  value = var.domain
  tags  = var.tags
}

resource "aws_ssm_parameter" "jwt_secret" {
  name  = "${local.prefix}/JWT_SECRET"
  type  = "SecureString"
  value = random_password.jwt_secret.result
  tags  = var.tags
}

# IAM role for the Lightsail VM to read SSM parameters.
resource "aws_iam_role" "lightsail_ssm" {
  name = "${var.naming_prefix}-lightsail-ssm"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "lightsail_ssm" {
  role = aws_iam_role.lightsail_ssm.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParameters",
          "ssm:GetParametersByPath",
        ]
        Resource = "arn:aws:ssm:*:*:parameter${local.prefix}/*"
      },
    ]
  })
}
