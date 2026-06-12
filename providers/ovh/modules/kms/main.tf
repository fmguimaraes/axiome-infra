# SCAFFOLD (OVH KMS — FR6 / NFR5). Not wired or tested yet; refine + validate
# against the ovh provider schema before apply (planned: 2026-06-12 test pass).
#
# Intended implementation — OVH Key Management Service (OKMS):
#
#   resource "ovh_okms" "data" {
#     ovh_subsidiary = "FR"
#     region         = var.ovh_region   # HDS-certified French region (CONTRACT §1)
#     display_name   = "${var.naming_prefix}-data"
#   }
#   # Service key (CMK) for data-at-rest:
#   resource "ovh_okms_service_key" "data" {
#     okms_id = ovh_okms.data.id
#     name    = "${var.naming_prefix}-data"
#     type    = "AES"
#     size    = 256
#     operations = ["encrypt", "decrypt"]
#   }
#
# Keep the output contract stable (key_arn/key_id) so the root composition is
# provider-agnostic — see providers/CONTRACT.md §6.

locals {
  # Filled once the resources above are enabled.
  key_arn = null
  key_id  = null
}
