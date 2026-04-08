resource "scaleway_object_bucket" "artifacts" {
  name   = "${var.naming_prefix}-artifacts"
  region = var.region

  versioning {
    enabled = true
  }

  tags = merge(
    { for t in var.tags : split(":", t)[0] => split(":", t)[1] if length(split(":", t)) == 2 },
    { "purpose" = "artifacts" }
  )
}

resource "scaleway_object_bucket" "uploads" {
  name   = "${var.naming_prefix}-uploads"
  region = var.region

  versioning {
    enabled = false
  }

  tags = merge(
    { for t in var.tags : split(":", t)[0] => split(":", t)[1] if length(split(":", t)) == 2 },
    { "purpose" = "uploads" }
  )
}

resource "scaleway_object_bucket" "system" {
  name   = "${var.naming_prefix}-system"
  region = var.region

  versioning {
    enabled = false
  }

  tags = merge(
    { for t in var.tags : split(":", t)[0] => split(":", t)[1] if length(split(":", t)) == 2 },
    { "purpose" = "system" }
  )
}

resource "scaleway_object_bucket" "frontend" {
  name   = "${var.naming_prefix}-frontend"
  region = var.region

  versioning {
    enabled = false
  }

  tags = merge(
    { for t in var.tags : split(":", t)[0] => split(":", t)[1] if length(split(":", t)) == 2 },
    { "purpose" = "frontend-static" }
  )
}

resource "scaleway_object_bucket_website_configuration" "frontend" {
  bucket = scaleway_object_bucket.frontend.id
  region = var.region

  index_document {
    suffix = "index.html"
  }

  error_document {
    key = "index.html"
  }
}
