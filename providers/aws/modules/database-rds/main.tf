# Amazon RDS for PostgreSQL — FR2 / NFR4 / NFR5 / AC3.
# Replaces Neon. Private subnets + data SG only (NFR7); CMK-encrypted at rest (FR6).
# Service schemas (user_svc, organization_svc) are applied by Prisma migrations.

resource "random_password" "db" {
  length  = 24
  special = false
}

# Least-privilege pilot-tenant runtime role (FR10 / NFR2 / AC8). The master user/
# password above are admin-only (schema migrations, one-off ops) and are never
# published to the app's runtime secrets — see modules/secrets, which wires
# app_runtime_connection_string (not `connection_string`) into DATABASE_URL /
# USER_DATABASE_URL / ORGANIZATION_DATABASE_URL. Terraform only generates the
# password; db/01_pilot_tenant_app_role.sql creates the role and its schema-scoped
# grants (run once per environment — see that file's header).
resource "random_password" "app_runtime" {
  length  = 24
  special = false
}

resource "aws_db_subnet_group" "this" {
  name       = "${var.naming_prefix}-pg"
  subnet_ids = var.subnet_ids
  tags       = merge(var.tags, { Name = "${var.naming_prefix}-pg" })
}

resource "aws_db_instance" "this" {
  identifier     = "${var.naming_prefix}-pg"
  engine         = "postgres"
  engine_version = var.engine_version
  instance_class = var.instance_class

  allocated_storage     = var.allocated_storage
  max_allocated_storage = var.max_allocated_storage

  db_name  = var.db_name
  username = var.username
  password = random_password.db.result

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = var.vpc_security_group_ids

  storage_encrypted = true
  kms_key_id        = var.kms_key_arn

  multi_az                  = var.multi_az
  backup_retention_period   = var.backup_retention_days
  deletion_protection       = var.environment == "production"
  skip_final_snapshot       = var.environment != "production"
  final_snapshot_identifier = var.environment == "production" ? "${var.naming_prefix}-pg-final" : null

  tags = merge(var.tags, { Name = "${var.naming_prefix}-pg" })
}
