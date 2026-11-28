# Knowledge content bucket + its one dedicated IAM principal (AXI-2798, epic
# AXI-2796, SI-040/SI-041). A deliberately SEPARATE module from `modules/storage` —
# not an instance of it — so no production app role can ever gain access to
# licensed full text by reuse (FR66/FR67/NFR12, epic decision). Account-shared:
# one bucket for the whole AWS account, instantiated once from the `shared/` root
# (the existing account-shared tfstate, FR8/AC8 pattern), never per-environment.
#
# This module creates NO access key (hard rule: never create or commit a key).
# The owner creates the IAM user's access key by hand (console or
# `aws iam create-access-key`) after apply and wires it into a named AWS CLI
# profile; the sync tooling (`datastore.py push|pull|check --remote`) resolves it
# through the standard AWS SDK credential chain (FR67) — this module only grants
# the permissions that key will carry.

locals {
  bucket_name = "${var.naming_prefix}-knowledge-store"
  user_name   = "${var.naming_prefix}-knowledge-tooling"
}

# ---------------- Bucket ----------------

resource "aws_s3_bucket" "knowledge" {
  bucket = local.bucket_name
  tags   = merge(var.tags, { Purpose = "knowledge-content-store" })
}

resource "aws_s3_bucket_versioning" "knowledge" {
  bucket = aws_s3_bucket.knowledge.id
  versioning_configuration {
    status = "Enabled"
  }
}

# All four Block Public Access settings on (FR66, AC31). Licensed full text SHALL
# never become public — this is the structural guarantee, not merely the policy
# below.
resource "aws_s3_bucket_public_access_block" "knowledge" {
  bucket                  = aws_s3_bucket.knowledge.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Default encryption at rest (FR66, NFR12). SSE-S3 (AES256) unless a CMK ARN is
# supplied — this account-shared bucket has no platform CMK wired to it today, so
# the default path is AES256, same fallback `modules/storage`/`modules/tenant` use.
resource "aws_s3_bucket_server_side_encryption_configuration" "knowledge" {
  bucket = aws_s3_bucket.knowledge.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = var.kms_key_arn == "" ? "AES256" : "aws:kms"
      kms_master_key_id = var.kms_key_arn == "" ? null : var.kms_key_arn
    }
    bucket_key_enabled = var.kms_key_arn != ""
  }
}

# TLS-only (encryption in transit, NFR12). Denies any request — including from the
# bucket owner — made without aws:SecureTransport. This is in addition to, not
# instead of, the public-access block above.
resource "aws_s3_bucket_policy" "knowledge_tls_only" {
  bucket = aws_s3_bucket.knowledge.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource = [
        aws_s3_bucket.knowledge.arn,
        "${aws_s3_bucket.knowledge.arn}/*",
      ]
      Condition = {
        Bool = { "aws:SecureTransport" = "false" }
      }
    }]
  })
}

# Lifecycle (FR66, AC31, O19 ruled):
#   - noncurrent object versions (any prefix) expire after 90 days;
#   - `backup/` objects (the FR70/O22 git-bundle custody copy) expire 180 days
#     after creation;
#   - `sha256/` content objects never expire (no expiration rule targets them);
#   - storage class stays S3 Standard throughout (no transition rule — Standard is
#     the default class for every PUT, so this is satisfied by the absence of a
#     transition action, not by an explicit setting).
resource "aws_s3_bucket_lifecycle_configuration" "knowledge" {
  bucket = aws_s3_bucket.knowledge.id

  rule {
    id     = "expire-noncurrent-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 90
    }
  }

  rule {
    id     = "expire-backup-objects"
    status = "Enabled"

    filter {
      prefix = "backup/"
    }

    expiration {
      days = 180
    }
  }
}

# ---------------- The one dedicated knowledge-tooling IAM principal ----------------
# O18 ruled: exactly one principal, read/write + list on this bucket only, no CI
# access. Scoped to ONLY this bucket's ARN — no wildcard, no other bucket, no other
# resource — so it structurally cannot reach the platform storage/tenant buckets
# and no production role can reuse it.

resource "aws_iam_user" "knowledge_tooling" {
  name = local.user_name
  tags = merge(var.tags, { Purpose = "knowledge-content-store" })
}

resource "aws_iam_user_policy" "knowledge_tooling" {
  name = "knowledge-bucket-read-write"
  user = aws_iam_user.knowledge_tooling.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "KnowledgeBucketList"
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:GetBucketLocation"]
        Resource = aws_s3_bucket.knowledge.arn
      },
      {
        Sid    = "KnowledgeObjectReadWrite"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:AbortMultipartUpload",
          "s3:ListMultipartUploadParts",
        ]
        Resource = "${aws_s3_bucket.knowledge.arn}/*"
      },
    ]
  })
}
