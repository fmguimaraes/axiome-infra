environment  = "production"
project_name = "axiome"

ovh_region    = "GRA11"
ovh_s3_region = "gra"

domain = "axiomebio.com"
# MIPP pilot host -> aphm-mipp.axiomebio.com (FR7)
subdomain = "aphm-mipp"

# Production / pilot sizing — b3-16 = 4 vCPU / 16 GB
ovh_instance_flavor              = "b3-16"
ovh_instance_image               = "Ubuntu 22.04"
ovh_instance_root_volume_size_gb = 80

neon_project_region_id   = "aws-eu-central-1"
neon_compute_min_cu      = 0.25
neon_compute_max_cu      = 2.0
neon_autosuspend_seconds = 0

atlas_org_id         = ""
atlas_cluster_tier   = "M10"
atlas_cloud_provider = "AWS"
atlas_region         = "EU_CENTRAL_1"
atlas_mongo_version  = "7.0"

backend_image_tag    = "latest"
biocompute_image_tag = "latest"
frontend_image_tag   = "latest"

tags = ["tier:production"]
