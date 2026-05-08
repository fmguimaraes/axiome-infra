environment   = "staging"
project_name  = "axiome"
aws_region    = "eu-west-3"

domain    = "axiome.example.com"
subdomain = "staging"

# Lightsail — same tier as dev
lightsail_blueprint_id      = "ubuntu_22_04"
lightsail_bundle_id         = "small_arm_3_0"
lightsail_availability_zone = "eu-west-3a"

# Neon — Launch tier recommended for staging (no autosuspend)
neon_project_region_id   = "aws-eu-central-1"
neon_compute_min_cu      = 0.25
neon_compute_max_cu      = 1.0
neon_autosuspend_seconds = 0

# Atlas — M0 if cost-constrained, M10 for production-shape validation
atlas_org_id         = ""
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
