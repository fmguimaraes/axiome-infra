resource "scaleway_object_bucket" "artifacts" {
  name   = "${var.naming_prefix}-artifacts"
  region = var.region

  versioning {
    enabled = true
  }

  tags = {
    purpose = "artifacts"
  }
}

resource "scaleway_object_bucket" "uploads" {
  name   = "${var.naming_prefix}-uploads"
  region = var.region

  tags = {
    purpose = "uploads"
  }
}

resource "scaleway_object_bucket" "system" {
  name   = "${var.naming_prefix}-system"
  region = var.region

  tags = {
    purpose = "system"
  }
}

resource "scaleway_object_bucket_lifecycle_configuration" "system" {
  bucket = scaleway_object_bucket.system.name
  region = var.region

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

# IAM application + access keys for the VM to read/write S3-compatible storage.
resource "scaleway_iam_application" "vm_runtime" {
  name        = "${var.naming_prefix}-vm-runtime"
  description = "Runtime credentials for ${var.naming_prefix} compute VM"
}

resource "scaleway_iam_policy" "vm_runtime_storage" {
  name           = "${var.naming_prefix}-vm-storage"
  application_id = scaleway_iam_application.vm_runtime.id

  rule {
    project_ids          = [data.scaleway_account_project.current.id]
    permission_set_names = ["ObjectStorageFullAccess"]
  }
}

resource "scaleway_iam_api_key" "vm_runtime" {
  application_id = scaleway_iam_application.vm_runtime.id
  description    = "Runtime access key for ${var.naming_prefix} VM"
}

data "scaleway_account_project" "current" {}
