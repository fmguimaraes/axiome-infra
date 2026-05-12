environment  = "production"
project_name = "axiome"
aws_region   = "eu-west-3"

# DNS managed manually at Hostinger — see providers/aws/README.md §0.4.
domain      = "axiomebio.com"
subdomain   = "platform" # production serves at platform.axiomebio.com (apex is the marketing landing page)
use_route53 = false

# Lightsail — production gets 4 GB headroom (medium_3_0). eu-west-3 has no ARM.
# Upgrade triggers documented in graduation-criteria.md
lightsail_blueprint_id      = "ubuntu_22_04"
lightsail_bundle_id         = "medium_3_0"
lightsail_availability_zone = "eu-west-3a"

# Neon — Launch tier minimum for production. Upgrade to Scale per graduation criteria.
neon_project_region_id         = "aws-eu-central-1"
neon_compute_min_cu            = 0.5
neon_compute_max_cu            = 2.0
neon_autosuspend_seconds       = 0
neon_history_retention_seconds = 604800 # 7 days; requires Launch+ (Scale supports up to 30d)

# Atlas — M10 minimum for production multi-tenant
atlas_org_id         = ""
atlas_cluster_tier   = "M10"
atlas_cloud_provider = "AWS"
atlas_region         = "EU_CENTRAL_1"
atlas_mongo_version  = "7.0"

backend_image_tag    = "stable"
biocompute_image_tag = "stable"
frontend_image_tag   = "stable"

common_tags = {
  Tier = "production"
}
