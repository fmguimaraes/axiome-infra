# SCAFFOLD (Scaleway Managed Database for PostgreSQL — FR2). Not tested yet; refine +
# validate before apply (planned 2026-06-12). Mirrors the AWS database-rds output
# contract so the root composition stays provider-agnostic (CONTRACT §3/§4).
#
# Intended implementation:
#
#   resource "scaleway_rdb_instance" "pg" {
#     name           = "${var.naming_prefix}-pg"
#     engine         = var.engine_version      # e.g. "PostgreSQL-16"
#     node_type      = var.node_type
#     region         = var.scaleway_region     # fr-par (CONTRACT §1)
#     is_ha_cluster  = var.environment == "production"
#     private_network {
#       pn_id = var.private_network_id          # private-only (NFR7)
#     }
#     # disable public endpoint; encryption at rest is platform-managed.
#   }
#   resource "scaleway_rdb_database" "axiome" { name = "axiome" }
#   resource "scaleway_rdb_user" "app" { ... }

locals {
  endpoint          = null
  port              = null
  db_name           = "axiome"
  username          = "axiome"
  connection_string = null
}
