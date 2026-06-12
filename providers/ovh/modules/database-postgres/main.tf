# SCAFFOLD (OVH Managed Databases for PostgreSQL — FR2). Not tested yet; refine +
# validate before apply (planned 2026-06-12). Mirrors the AWS database-rds output
# contract (endpoint/port/db_name/username/password/connection_string) so the root
# composition stays provider-agnostic (CONTRACT §3/§4).
#
# Intended implementation:
#
#   resource "ovh_cloud_project_database" "pg" {
#     service_name = var.ovh_cloud_project_id
#     engine       = "postgresql"
#     version      = var.engine_version
#     plan         = "essential"
#     nodes {
#       region = var.ovh_region        # HDS-certified French region (CONTRACT §1)
#     }
#     # attach to var.private_network_id for private-only access (NFR7)
#   }
#   resource "ovh_cloud_project_database_postgresql_user" "app" { ... }
#   resource "ovh_cloud_project_database_database" "axiome" { name = "axiome" }
#
# Encryption at rest: OVH Managed Databases are encrypted by the platform; document
# the key custody in the HDS evidence report (FR13).

locals {
  endpoint          = null
  port              = null
  db_name           = "axiome"
  username          = "axiome"
  connection_string = null
}
