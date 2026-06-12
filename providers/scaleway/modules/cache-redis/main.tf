# SCAFFOLD (Scaleway Managed Redis — FR5). Not tested yet; refine + validate before
# apply. Mirrors the AWS cache-redis output contract (redis_url) behind the Redis
# protocol so the app's REDIS_URL is provider-agnostic (CONTRACT §3).
#
# Intended implementation:
#   resource "scaleway_redis_cluster" "this" {
#     name         = "${var.naming_prefix}-redis"
#     version      = "7.0.5"
#     node_type    = var.node_type
#     cluster_size = var.environment == "production" ? 3 : 1
#     zone         = "${var.scaleway_region}-1"
#     tls_enabled  = true
#     private_network { id = var.private_network_id }   # private-only (NFR7)
#   }

locals {
  primary_endpoint = null
  redis_url        = null
}
