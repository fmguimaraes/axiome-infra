# Per-tenant storage isolation unit (FR10, FR11, NFR1 · AC1 storage / AC6 bucket).
#
# One instance of this module = one tenant's complete object-storage boundary:
# its own S3 bucket + its own least-privilege IAM role scoped to ONLY that bucket
# and its KMS key. Instantiated via for_each over the tenant set in
# providers/aws/main.tf (a Factory producing one isolation unit per tenant); the
# bucket name and role ARN it outputs are the Tenant Registry's `bucket_ref` and
# `credential_ref` (FR2). There is deliberately NO wildcard grant anywhere in this
# module — cross-tenant reach is structurally impossible, not merely unused.

data "aws_caller_identity" "current" {}

locals {
  bucket_name = "${var.naming_prefix}-tenant-${var.tenant_id}"
  role_name   = "${var.naming_prefix}-tenant-${var.tenant_id}"

  # Who may assume the per-tenant role (AXI-1299 per-job STS). Falls back to the
  # account root so the delegation is governed by the caller's IAM policy.
  assume_principals = length(var.assume_role_principal_arns) > 0 ? var.assume_role_principal_arns : [
    "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
  ]
}

# ---------------- Per-tenant bucket ----------------

resource "aws_s3_bucket" "tenant" {
  bucket = local.bucket_name
  tags = merge(var.tags, {
    Purpose  = "tenant-data"
    TenantId = var.tenant_id
  })
}

resource "aws_s3_bucket_versioning" "tenant" {
  bucket = aws_s3_bucket.tenant.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "tenant" {
  bucket                  = aws_s3_bucket.tenant.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# SSE-KMS with the per-tenant CMK (NFR2/AC1). All object classes — raw uploads,
# canonical Parquet, derived tables, and rendered-charts/ — live under this one
# bucket, so every object class is encrypted with the tenant's key and sits inside
# the tenant boundary (FR10 — closes DEF-3, the rendered-charts/ leak).
resource "aws_s3_bucket_server_side_encryption_configuration" "tenant" {
  bucket = aws_s3_bucket.tenant.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = var.kms_key_arn == "" ? "AES256" : "aws:kms"
      kms_master_key_id = var.kms_key_arn == "" ? null : var.kms_key_arn
    }
    bucket_key_enabled = var.kms_key_arn != ""
  }
}

resource "aws_s3_bucket_cors_configuration" "tenant" {
  count  = length(var.cors_allowed_origins) > 0 ? 1 : 0
  bucket = aws_s3_bucket.tenant.id

  cors_rule {
    allowed_methods = ["PUT", "GET", "HEAD"]
    allowed_origins = var.cors_allowed_origins
    allowed_headers = ["*"]
    expose_headers  = ["ETag"]
    max_age_seconds = 3000
  }
}

# ---------------- Per-tenant IAM role ----------------
# Scoped to ONLY this tenant's bucket + KMS key (FR11). No `-*` wildcard, no
# access to any other tenant's bucket or the shared platform buckets. This is the
# role AXI-1299 assumes per job to hand a compute job tenant-scoped credentials
# that cannot reach another tenant (FR12) — replacing the removed all-tenant grant.

resource "aws_iam_role" "tenant" {
  name = local.role_name

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = local.assume_principals }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = merge(var.tags, { TenantId = var.tenant_id })
}

resource "aws_iam_role_policy" "tenant_s3" {
  name = "tenant-bucket-access"
  role = aws_iam_role.tenant.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          Sid      = "TenantBucketList"
          Effect   = "Allow"
          Action   = ["s3:ListBucket", "s3:GetBucketLocation"]
          Resource = aws_s3_bucket.tenant.arn
        },
        {
          Sid      = "TenantObjectAccess"
          Effect   = "Allow"
          Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
          Resource = "${aws_s3_bucket.tenant.arn}/*"
        },
      ],
      # KMS grant scoped to exactly the tenant CMK — writing an SSE-KMS object needs
      # GenerateDataKey, reading needs Decrypt. Omitted when the bucket is SSE-S3.
      var.kms_key_arn == "" ? [] : [{
        Sid      = "TenantKmsForS3Sse"
        Effect   = "Allow"
        Action   = ["kms:GenerateDataKey", "kms:Decrypt", "kms:Encrypt", "kms:ReEncrypt*", "kms:DescribeKey"]
        Resource = [var.kms_key_arn]
      }]
    )
  })
}
