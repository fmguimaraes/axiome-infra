environment      = "dev"
project_name     = "axiome"
scaleway_region  = "fr-par"
scaleway_zone    = "fr-par-1"

domain    = "axiome.example.com"
subdomain = "dev"

# Scaleway Instance — PLAY2-PICO is ~€7/mo with 2 vCPU / 2 GB RAM
# For 4 GB use DEV1-M (~€12/mo) or PRO2-XXS
instance_type                = "PLAY2-PICO"
instance_image               = "ubuntu_jammy"
instance_root_volume_size_gb = 40

# Neon — free tier
neon_project_region_id   = "aws-eu-central-1"
neon_compute_min_cu      = 0.25
neon_compute_max_cu      = 0.25
neon_autosuspend_seconds = 300

# Atlas — M0 free
atlas_org_id         = ""
atlas_cluster_tier   = "M0"
atlas_cloud_provider = "AWS"
atlas_region         = "EU_CENTRAL_1"
atlas_mongo_version  = "7.0"

backend_image_tag    = "latest"
biocompute_image_tag = "latest"
frontend_image_tag   = "latest"

tags = ["tier:dev"]
