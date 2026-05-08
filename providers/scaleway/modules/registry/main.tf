resource "scaleway_registry_namespace" "main" {
  name        = "${var.naming_prefix}-registry"
  region      = var.region
  is_public   = false
  description = "Container registry for ${var.naming_prefix}"
}

# Token for pull access from the VM. Never leaks via outputs (sensitive).
# Note: Scaleway registry credentials are tied to IAM applications; for
# simplicity we reuse a service account access key pattern via a dedicated
# IAM application below. Replace with a finer-grained read-only token once
# Scaleway adds first-class registry tokens.
resource "scaleway_iam_application" "registry_pull" {
  name        = "${var.naming_prefix}-registry-pull"
  description = "Pull-only registry access for ${var.naming_prefix} VM"
}

resource "scaleway_iam_policy" "registry_pull" {
  name           = "${var.naming_prefix}-registry-pull"
  application_id = scaleway_iam_application.registry_pull.id

  rule {
    project_ids          = [data.scaleway_account_project.current.id]
    permission_set_names = ["ContainerRegistryReadOnly"]
  }
}

resource "scaleway_iam_api_key" "registry_pull" {
  application_id = scaleway_iam_application.registry_pull.id
  description    = "Pull-only registry token for ${var.naming_prefix}"
}

data "scaleway_account_project" "current" {}
