# SCAFFOLD (OVH Object Storage, S3-compatible — FR11). Not tested yet; refine +
# validate before apply (planned 2026-06-12). Mirrors the AWS/Scaleway storage output
# contract (endpoint + *_bucket_name + access keys) so the app's @aws-sdk/client-s3
# works via configurable endpoint/region (CONTRACT §3).
#
# Intended implementation (OVH High-Performance Object Storage is S3-compatible):
#
#   resource "ovh_cloud_project_storage" "artifacts" {
#     service_name = var.ovh_cloud_project_id
#     region_name  = upper(var.ovh_s3_region)   # e.g. GRA
#     name         = "${var.naming_prefix}-artifacts"
#   }
#   # ...uploads, system buckets; plus an S3 credential (ovh_cloud_project_user_s3_credential)
#   # for runtime access. Endpoint: https://s3.<region>.io.cloud.ovh.net
#
# Encryption at rest is platform-managed; record key custody in the HDS report (FR13).

locals {
  endpoint              = "https://s3.${var.ovh_s3_region}.io.cloud.ovh.net"
  artifacts_bucket_name = "${var.naming_prefix}-artifacts"
  uploads_bucket_name   = "${var.naming_prefix}-uploads"
  system_bucket_name    = "${var.naming_prefix}-system"
}
