# Runtime secrets store (AXI-990 / FR3, CONTRACT §4 `secrets`).
#
# Mirrors the AWS SSM Parameter Store module: one managed secret per runtime config
# key, under a per-environment path, in the sovereign French region (fr-par). Values
# are supplied by the root from the database/storage modules and generated passwords;
# they are never printed (sensitive). Least-privilege read access is granted to the
# compute identity via the registry/storage IAM applications (ObjectStorage/Registry
# sets) plus a Secret-Manager read policy attached out of band to the runtime app.

# Secret *names* are not sensitive (DATABASE_URL, JWT_SECRET, ...); only the values
# are. Drive for_each off the non-sensitive key set so instance addresses stay clean,
# and pull the sensitive value by key for the version payload.
locals {
  secret_keys = nonsensitive(toset(keys(var.secrets)))
}

resource "scaleway_secret" "this" {
  for_each = local.secret_keys

  name        = "${var.naming_prefix}-${each.key}"
  path        = "/${var.environment}/${var.naming_prefix}"
  region      = var.scaleway_region
  description = "Runtime secret ${each.key} for ${var.naming_prefix}"
  tags        = var.tags
}

resource "scaleway_secret_version" "this" {
  for_each = local.secret_keys

  secret_id = scaleway_secret.this[each.key].id
  data      = var.secrets[each.key]
}
