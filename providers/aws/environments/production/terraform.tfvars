environment  = "production"
project_name = "axiome"
aws_region   = "eu-west-3"

# DNS managed manually at Microsoft 365 — see providers/aws/README.md §0.4.
domain      = "axiomebio.com"
subdomain   = "platform" # production serves at platform.axiomebio.com (apex is the marketing landing page)
use_route53 = false

# --- HDS cutover (AXI-916) — stand up the new stack alongside Lightsail (strangler) ---
use_hds_data_stack = true  # VPC + 3-tier SGs + RDS + ElastiCache
use_ec2_compute    = true  # EC2 + Elastic IP (the Microsoft 365 A-record target)
use_legacy_stack   = false # greenfield production — no Lightsail (nothing to keep/roll back to)
# ECR repos (axiome/backend|biocompute|frontend) + the ecr-pull role are account-level and already
# exist (created by dev) — reference them, don't recreate.
create_ecr_repositories = false

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

# Atlas — event/audit store, M10 minimum for production (dedicated tier: needed for
# a real replica set + Atlas Cloud Backup; M0/M2/M5 don't offer either). Same Atlas
# org as dev/staging (one org covers all environments — see variables.tf). Region is
# EU_WEST_3 (Paris), matching aws_region, to preserve HDS French-region data
# residency (NFR2) — EU_CENTRAL_1 (Frankfurt) would violate it.
atlas_org_id         = "6a009f5d529be1fb7cad2dc1"
atlas_cluster_tier   = "M10"
atlas_cloud_provider = "AWS"
atlas_region         = "EU_WEST_3"
atlas_mongo_version  = "7.0"

backend_image_tag    = "stable"
biocompute_image_tag = "stable"
frontend_image_tag   = "stable"

common_tags = {
  Tier = "production"
}
