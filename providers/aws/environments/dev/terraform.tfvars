environment   = "dev"
project_name  = "axiome"
aws_region    = "eu-west-3"

# Domain — set to your registered domain. Route 53 hosted zone for var.domain
# must already exist (manual one-time setup; not Terraform-managed).
domain    = "axiome.example.com"
subdomain = "dev"

# Lightsail — cheapest ARM tier, 4 GB RAM
lightsail_blueprint_id      = "ubuntu_22_04"
lightsail_bundle_id         = "small_arm_3_0"
lightsail_availability_zone = "eu-west-3a"

# Neon — free tier (autosuspend 5min)
neon_project_region_id  = "aws-eu-central-1"
neon_compute_min_cu     = 0.25
neon_compute_max_cu     = 0.25
neon_autosuspend_seconds = 300

# Atlas — M0 free tier
atlas_org_id         = ""  # Set via TF_VAR_atlas_org_id env var or override
atlas_cluster_tier   = "M0"
atlas_cloud_provider = "AWS"
atlas_region         = "EU_CENTRAL_1"
atlas_mongo_version  = "7.0"

# Image tags — overridden by CI via images.tfvars
backend_image_tag    = "latest"
biocompute_image_tag = "latest"
frontend_image_tag   = "latest"

common_tags = {
  Tier = "dev"
}
