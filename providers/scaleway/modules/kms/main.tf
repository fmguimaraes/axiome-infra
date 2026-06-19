# Scaleway Key Manager CMK (AXI-991 / FR6, NFR5, CONTRACT §6).
# Customer-managed key for data-at-rest in the sovereign French region (fr-par):
# object storage, instance volumes, secrets, backups. Output contract stays stable
# (key_id) so the root composition is provider-agnostic.

resource "scaleway_key_manager_key" "data" {
  name        = "${var.naming_prefix}-data"
  region      = var.scaleway_region
  description = "Data-at-rest CMK for ${var.naming_prefix} (object storage, volumes, secrets, backups)"

  usage     = "symmetric_encryption"
  algorithm = "aes_256_gcm"
}
