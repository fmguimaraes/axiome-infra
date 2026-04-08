environment   = "dev"
provider_name = "scaleway"
region        = "fr-par"
zone          = "fr-par-1"
project_name  = "axiome"

# Database sizing — minimal for dev
postgres_node_type = "DB-DEV-S"
mongodb_node_type  = "MGDB-PLAY2-NANO"

# Compute sizing — minimal for dev
backend_min_scale      = 1
backend_max_scale      = 1
backend_cpu_limit      = 500
backend_memory_limit   = 512
biocompute_min_scale   = 1
biocompute_max_scale   = 1
biocompute_cpu_limit   = 1000
biocompute_memory_limit = 1024

# Feature flags
enable_monitoring         = true
enable_frontend_container = false

tags = ["tier:dev"]
