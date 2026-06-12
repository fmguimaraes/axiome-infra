# SCAFFOLD (OVH managed Redis — FR5). Not tested yet; refine + validate before apply.
# Mirrors the AWS cache-redis output contract (redis_url) behind the Redis protocol so
# the app's REDIS_URL is provider-agnostic (CONTRACT §3).
#
# Intended implementation:
#   resource "ovh_cloud_project_database" "redis" {
#     service_name = var.ovh_cloud_project_id
#     engine       = "redis"
#     version      = "7.2"
#     plan         = "essential"
#     nodes { region = var.ovh_region }   # HDS French region (CONTRACT §1)
#     # private-network attachment for private-only access (NFR7)
#   }

locals {
  primary_endpoint = null
  redis_url        = null
}
