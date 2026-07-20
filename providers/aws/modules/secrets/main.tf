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

resource "random_password" "rabbitmq" {
  length  = 32
  special = false
}

# Root password for the in-region self-hosted Mongo container (FR3). Always
# generated so the container can start; only used by the app when use_inregion_mongo.
resource "random_password" "mongo" {
  length  = 32
  special = false
}

locals {
  inregion_mongodb_url = "mongodb://axiome:${random_password.mongo.result}@mongo:27017/axiome?authSource=admin"
}

locals {
  # Least-privilege pilot-tenant role when available (HDS/RDS stack — FR10/NFR2);
  # falls back to the master URL only on the legacy Neon path, which has no scoped
  # runtime role. App containers should never receive master credentials on the
  # RDS path — see modules/database-rds `app_runtime_connection_string`.
  runtime_postgres_url = coalesce(var.postgres_app_url != "" ? var.postgres_app_url : null, var.postgres_url)
}

resource "aws_ssm_parameter" "database_url" {
  name  = "${local.prefix}/DATABASE_URL"
  type  = "SecureString"
  value = local.runtime_postgres_url
  tags  = var.tags
}

resource "aws_ssm_parameter" "mongodb_url" {
  name  = "${local.prefix}/MONGODB_URL"
  type  = "SecureString"
  value = var.use_inregion_mongo ? local.inregion_mongodb_url : var.mongodb_url
  tags  = var.tags
}

# Root password consumed by the in-region Mongo container (compose MONGO_ROOT_PASSWORD).
resource "aws_ssm_parameter" "mongo_root_password" {
  name  = "${local.prefix}/MONGO_ROOT_PASSWORD"
  type  = "SecureString"
  value = random_password.mongo.result
  tags  = var.tags
}

# REDIS_URL — only published when provided (e.g. ElastiCache). Absent = app uses
# its local Redis container default (compose REDIS_URL fallback). FR5.
resource "aws_ssm_parameter" "redis_url" {
  count = var.publish_redis_url ? 1 : 0
  name  = "${local.prefix}/REDIS_URL"
  type  = "SecureString"
  value = var.redis_url
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

# Per-service Postgres URLs, isolated via per-service Postgres schemas (`?schema=`)
# so one service's Prisma client can't touch another's tables. On the RDS/HDS path
# these also carry the least-privilege pilot-tenant role (local.runtime_postgres_url
# — FR10/NFR2), not the master user; on the legacy Neon path they still carry the
# master user (no scoped role exists there). Each schema must be created
# (CREATE SCHEMA <name>) before Prisma migrates against it.
locals {
  separator = strcontains(local.runtime_postgres_url, "?") ? "&" : "?"
}

resource "aws_ssm_parameter" "user_database_url" {
  name  = "${local.prefix}/USER_DATABASE_URL"
  type  = "SecureString"
  value = "${local.runtime_postgres_url}${local.separator}schema=user_svc"
  tags  = var.tags
}

resource "aws_ssm_parameter" "organization_database_url" {
  name  = "${local.prefix}/ORGANIZATION_DATABASE_URL"
  type  = "SecureString"
  value = "${local.runtime_postgres_url}${local.separator}schema=organization_svc"
  tags  = var.tags
}

resource "aws_ssm_parameter" "rabbitmq_user" {
  name  = "${local.prefix}/RABBITMQ_USER"
  type  = "String"
  value = "axiome"
  tags  = var.tags
}

resource "aws_ssm_parameter" "rabbitmq_password" {
  name  = "${local.prefix}/RABBITMQ_PASSWORD"
  type  = "SecureString"
  value = random_password.rabbitmq.result
  tags  = var.tags
}

resource "aws_ssm_parameter" "cors_origins" {
  name  = "${local.prefix}/CORS_ORIGINS"
  type  = "String"
  value = "https://${var.fqdn}"
  tags  = var.tags
}

# Public app URL the backend embeds in transactional emails (password reset,
# welcome, export, sponsor publish). Without this, EmailService falls back to
# http://localhost:5173 and every prod email link is broken.
resource "aws_ssm_parameter" "frontend_url" {
  name  = "${local.prefix}/FRONTEND_URL"
  type  = "String"
  value = "https://${var.fqdn}"
  tags  = var.tags
}

# Published only when provided — SSM rejects empty SecureString values, and an
# absent key simply leaves EmailService in its log-only fallback (no send).
resource "aws_ssm_parameter" "mailjet_api_key" {
  count = var.mailjet_api_key != "" ? 1 : 0
  name  = "${local.prefix}/MAILJET_API_KEY"
  type  = "SecureString"
  value = var.mailjet_api_key
  tags  = var.tags
}

resource "aws_ssm_parameter" "mailjet_secret_key" {
  count = var.mailjet_secret_key != "" ? 1 : 0
  name  = "${local.prefix}/MAILJET_SECRET_KEY"
  type  = "SecureString"
  value = var.mailjet_secret_key
  tags  = var.tags
}

resource "aws_ssm_parameter" "mailjet_from_email" {
  name  = "${local.prefix}/MAILJET_FROM_EMAIL"
  type  = "String"
  value = var.mailjet_from_email
  tags  = var.tags
}

resource "aws_ssm_parameter" "mailjet_from_name" {
  name  = "${local.prefix}/MAILJET_FROM_NAME"
  type  = "String"
  value = var.mailjet_from_name
  tags  = var.tags
}

# IAM role for the Lightsail VM to read SSM parameters. Only created for the
# legacy Lightsail compute path (var.create_lightsail_iam). The EC2/HDS stack
# uses its own instance profile (modules/compute-ec2), so this is not created.
resource "aws_iam_role" "lightsail_ssm" {
  count = var.create_lightsail_iam ? 1 : 0
  name  = "${var.naming_prefix}-lightsail-ssm"

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
  count = var.create_lightsail_iam ? 1 : 0
  role  = aws_iam_role.lightsail_ssm[0].id

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
