environment     = "staging"
project_name    = "axiome"
scaleway_region = "fr-par"
scaleway_zone   = "fr-par-1"

domain    = "axiome.example.com"
subdomain = "staging"

instance_type                = "DEV1-M"
instance_image               = "ubuntu_jammy"
instance_root_volume_size_gb = 40

neon_project_region_id   = "aws-eu-central-1"
neon_compute_min_cu      = 0.25
neon_compute_max_cu      = 1.0
neon_autosuspend_seconds = 0

atlas_org_id         = ""
atlas_cluster_tier   = "M0"
atlas_cloud_provider = "AWS"
atlas_region         = "EU_CENTRAL_1"
atlas_mongo_version  = "7.0"

backend_image_tag    = "latest"
biocompute_image_tag = "latest"
frontend_image_tag   = "latest"

tags = ["tier:staging"]
