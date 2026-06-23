resource "aws_s3_bucket" "artifacts" {
  bucket = "${var.naming_prefix}-artifacts"
  tags   = merge(var.tags, { Purpose = "artifacts" })
}

resource "aws_s3_bucket_versioning" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket                  = aws_s3_bucket.artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = var.kms_key_arn == "" ? "AES256" : "aws:kms"
      kms_master_key_id = var.kms_key_arn == "" ? null : var.kms_key_arn
    }
    bucket_key_enabled = var.kms_key_arn != ""
  }
}

resource "aws_s3_bucket" "uploads" {
  bucket = "${var.naming_prefix}-uploads"
  tags   = merge(var.tags, { Purpose = "uploads" })
}

resource "aws_s3_bucket_public_access_block" "uploads" {
  bucket                  = aws_s3_bucket.uploads.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "uploads" {
  bucket = aws_s3_bucket.uploads.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = var.kms_key_arn == "" ? "AES256" : "aws:kms"
      kms_master_key_id = var.kms_key_arn == "" ? null : var.kms_key_arn
    }
    bucket_key_enabled = var.kms_key_arn != ""
  }
}

# Browser uploads/downloads (logos, datasets) hit the uploads bucket directly via
# presigned URLs, so the bucket must allow CORS from the app origin only. Without
# this, the browser PUT is blocked by the same-origin policy. Scoped to the app
# origin(s); empty list disables CORS (e.g. non-browser-facing environments).
resource "aws_s3_bucket_cors_configuration" "uploads" {
  count  = length(var.cors_allowed_origins) > 0 ? 1 : 0
  bucket = aws_s3_bucket.uploads.id

  cors_rule {
    allowed_methods = ["PUT", "GET", "HEAD"]
    allowed_origins = var.cors_allowed_origins
    allowed_headers = ["*"]
    expose_headers  = ["ETag"]
    max_age_seconds = 3000
  }
}

resource "aws_s3_bucket" "system" {
  bucket = "${var.naming_prefix}-system"
  tags   = merge(var.tags, { Purpose = "system" })
}

resource "aws_s3_bucket_public_access_block" "system" {
  bucket                  = aws_s3_bucket.system.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "system" {
  bucket = aws_s3_bucket.system.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = var.kms_key_arn == "" ? "AES256" : "aws:kms"
      kms_master_key_id = var.kms_key_arn == "" ? null : var.kms_key_arn
    }
    bucket_key_enabled = var.kms_key_arn != ""
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "system" {
  bucket = aws_s3_bucket.system.id

  rule {
    id     = "expire-old-backups"
    status = "Enabled"

    filter {
      prefix = "backups/"
    }

    expiration {
      days = var.environment == "production" ? 90 : 30
    }
  }
}
