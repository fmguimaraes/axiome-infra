environment   = "production"
provider_name = "scaleway"
region        = "fr-par"
zone          = "fr-par-1"
project_name  = "axiome"

# Database sizing — production-grade
postgres_node_type = "DB-GP-XS"
mongodb_node_type  = "MGDB-PLAY2-NANO"

# Compute sizing — production-grade
backend_min_scale       = 2
backend_max_scale       = 4
backend_cpu_limit       = 2000
backend_memory_limit    = 2048
biocompute_min_scale    = 1
biocompute_max_scale    = 4
biocompute_cpu_limit    = 4000
biocompute_memory_limit = 4096

# Feature flags
enable_monitoring         = true
enable_frontend_container = false

tags = ["tier:production"]
