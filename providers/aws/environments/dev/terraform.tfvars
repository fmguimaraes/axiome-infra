environment  = "dev"
project_name = "axiome"
aws_region   = "eu-west-3"

# ECR repos are account-level shared. Dev owns them since it's the first env bootstrapped.
# When staging/production are added later, they should NOT manage the same repos —
# leave create_ecr_repositories unset (or = false) in their tfvars.
create_ecr_repositories = true

# Domain — DNS is managed manually at Hostinger (see providers/aws/README.md §0.4).
# After apply, retrieve lightsail_static_ip from outputs and create the matching A record.
# To switch to Terraform-managed Route 53, pre-create a hosted zone for var.domain and set use_route53 = true.
domain      = "axiomebio.com"
subdomain   = "dev"
use_route53 = false

# Lightsail — 4 GB RAM (eu-west-3 has no ARM bundles).
# Backend stack now runs 4 NestJS apps + rabbitmq + redis + biocompute + caddy + frontend
# ≈ 2.5 GB committed. small_3_0 (2 GB) was OOM-bound; bumped to medium_3_0.
lightsail_blueprint_id      = "ubuntu_22_04"
lightsail_bundle_id         = "medium_3_0"
lightsail_availability_zone = "eu-west-3a"
lightsail_key_pair_name     = "axiome-lightsail" # Imported via `aws lightsail import-key-pair`; matches ~/.ssh/axiome-lightsail

# Neon — free tier (autosuspend ~5min, fixed by Neon, not customizable)
neon_project_region_id   = "aws-eu-central-1"
neon_compute_min_cu      = 0.25
neon_compute_max_cu      = 0.25
neon_autosuspend_seconds = null # Free tier rejects any value; paid plans can set 0–N

# Atlas — M0 free tier
atlas_org_id         = "6a009f5d529be1fb7cad2dc1" # Set via TF_VAR_atlas_org_id env var or override
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

# Edge / TLS — terminate TLS at CloudFront, not on the VM. See variables.tf
# (use_cloudfront_edge) for the why. Caddy on the Lightsail VM switches to
# plain HTTP on :80 so CloudFront -> origin doesn't require a public-CA cert
# on the VM.
use_cloudfront_edge = true

# The ACM cert was hand-issued via `aws acm request-certificate` during
# incident response on 2026-05-12. The next apply imports it into state
# rather than creating a duplicate. Safe to remove once you've confirmed
# the import succeeded.
import_acm_cert_arn = "arn:aws:acm:us-east-1:225201317100:certificate/980c6b8a-0aff-415c-b091-77351a8fa991"
