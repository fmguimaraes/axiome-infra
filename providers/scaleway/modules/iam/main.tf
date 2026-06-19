# Sovereign IAM domain (AXI-990 / FR2, FR3, NFR1, NFR3).
#
# The Scaleway Organization + Project are the sovereign tenancy boundary. The
# Organization and the dedicated Project are provisioned once as bootstrap (console
# or a separate bootstrap apply) and selected by the provider via `project_id`
# (providers/scaleway/main.tf); this module codifies the IAM *domain* inside that
# project: a deploy/CI identity scoped to the project (least-privilege at the project
# boundary, no org-wide grant) with its own API key — never shared with AWS (NFR3).

data "scaleway_account_project" "sovereign" {}

resource "scaleway_iam_application" "deploy" {
  name        = "${var.naming_prefix}-deploy"
  description = "Terraform/CI deploy identity for the sovereign ${var.naming_prefix} project"
}

resource "scaleway_iam_group" "deploy" {
  name            = "${var.naming_prefix}-deploy"
  description     = "Sovereign deploy/CI group for ${var.naming_prefix}"
  application_ids = [scaleway_iam_application.deploy.id]
}

# Project-scoped full access: the deploy identity manages everything inside the
# sovereign project only (CONTRACT §4). It is NOT an Organization-wide grant.
resource "scaleway_iam_policy" "deploy" {
  name        = "${var.naming_prefix}-deploy"
  description = "Project-scoped full access for the sovereign deploy identity"
  group_id    = scaleway_iam_group.deploy.id

  rule {
    project_ids          = [data.scaleway_account_project.sovereign.id]
    permission_set_names = ["AllProductsFullAccess"]
  }
}

resource "scaleway_iam_api_key" "deploy" {
  application_id = scaleway_iam_application.deploy.id
  description    = "Sovereign deploy API key for ${var.naming_prefix} (rotate on cutover)"
}
