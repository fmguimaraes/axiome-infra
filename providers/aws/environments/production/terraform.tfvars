environment   = "production"
project_name  = "axiome"
aws_region    = "eu-west-3"

domain    = "axiome.example.com"
subdomain = ""  # Apex — production serves at <domain> directly

# Lightsail — same tier (Phase 1 production); upgrade trigger documented in graduation-criteria.md
lightsail_blueprint_id      = "ubuntu_22_04"
lightsail_bundle_id         = "small_arm_3_0"
lightsail_availability_zone = "eu-west-3a"

# Neon — Launch tier minimum for production. Upgrade to Scale per graduation criteria.
neon_project_region_id   = "aws-eu-central-1"
neon_compute_min_cu      = 0.5
neon_compute_max_cu      = 2.0
neon_autosuspend_seconds = 0

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
