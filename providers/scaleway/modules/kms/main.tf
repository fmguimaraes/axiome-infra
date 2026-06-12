# SCAFFOLD (Scaleway Key Manager — FR6 / NFR5). Not wired or tested yet; refine +
# validate against the scaleway provider schema before apply (planned 2026-06-12).
#
# Intended implementation — Scaleway Key Manager:
#
#   resource "scaleway_key_manager_key" "data" {
#     name        = "${var.naming_prefix}-data"
#     region      = var.scaleway_region   # fr-par (CONTRACT §1)
#     usage       = "symmetric_encryption"
#     description = "Data-at-rest CMK (RDS-equiv, event store, object storage, volumes)"
#   }
#
# Keep the output contract stable (key_arn/key_id) so the root composition is
# provider-agnostic — see providers/CONTRACT.md §6.

locals {
  key_arn = null
  key_id  = null
}
