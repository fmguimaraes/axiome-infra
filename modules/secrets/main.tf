resource "scaleway_secret" "database_credentials" {
  name        = "${var.naming_prefix}-database-credentials"
  region      = var.region
  description = "Database credentials for Postgres and MongoDB"
  tags        = var.tags
}

resource "scaleway_secret" "api_secrets" {
  name        = "${var.naming_prefix}-api-secrets"
  region      = var.region
  description = "API secrets including JWT and session secrets"
  tags        = var.tags
}

resource "scaleway_secret" "storage_credentials" {
  name        = "${var.naming_prefix}-storage-credentials"
  region      = var.region
  description = "Object storage access credentials"
  tags        = var.tags
}
