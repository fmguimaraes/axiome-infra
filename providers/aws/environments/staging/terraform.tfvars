environment   = "staging"
project_name  = "axiome"
aws_region    = "eu-west-3"

# DNS managed manually at Hostinger — see providers/aws/README.md §0.4.
domain      = "axiomebio.com"
subdomain   = "staging"
use_route53 = false

# Lightsail — same tier as dev (eu-west-3 has no ARM; using x86)
lightsail_blueprint_id      = "ubuntu_22_04"
lightsail_bundle_id         = "small_3_0"
lightsail_availability_zone = "eu-west-3a"

# Neon — Launch tier recommended for staging (no autosuspend)
neon_project_region_id         = "aws-eu-central-1"
neon_compute_min_cu            = 0.25
neon_compute_max_cu            = 1.0
neon_autosuspend_seconds       = 0
neon_history_retention_seconds = 86400  # 1 day; requires Launch+ (Free max = 21600)

# Atlas — M0 if cost-constrained, M10 for production-shape validation
atlas_org_id         = "6a009f5d529be1fb7cad2dc1"
atlas_cluster_tier   = "M0"
atlas_cloud_provider = "AWS"
atlas_region         = "EU_CENTRAL_1"
atlas_mongo_version  = "7.0"

backend_image_tag    = "latest"
biocompute_image_tag = "latest"
frontend_image_tag   = "latest"

common_tags = {
  Tier = "staging"
}
