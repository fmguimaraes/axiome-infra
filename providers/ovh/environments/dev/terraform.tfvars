environment  = "dev"
project_name = "axiome"

# OVH Public Cloud — HDS-certified French region (CONTRACT §1)
ovh_region    = "GRA11"
ovh_s3_region = "gra"
# ovh_cloud_project_id set per-account (sensitive; supply via tfvars/secret, not committed)

domain    = "axiomebio.com"
subdomain = "dev"

# Compute — b3-8 = 2 vCPU / 8 GB
ovh_instance_flavor              = "b3-8"
ovh_instance_image               = "Ubuntu 22.04"
ovh_instance_root_volume_size_gb = 40

# Neon — free tier (migrates to managed Postgres in S4 / AXI-954)
neon_project_region_id   = "aws-eu-central-1"
neon_compute_min_cu      = 0.25
neon_compute_max_cu      = 0.25
neon_autosuspend_seconds = 300

# Atlas — M0 free (migrates to self-hosted in-region in S5 / AXI-955)
atlas_org_id         = ""
atlas_cluster_tier   = "M0"
atlas_cloud_provider = "AWS"
atlas_region         = "EU_CENTRAL_1"
atlas_mongo_version  = "7.0"

backend_image_tag    = "latest"
biocompute_image_tag = "latest"
frontend_image_tag   = "latest"

tags = ["tier:dev"]
