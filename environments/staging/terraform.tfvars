environment   = "staging"
provider_name = "scaleway"
region        = "fr-par"
zone          = "fr-par-1"
project_name  = "axiome"

# Database sizing — moderate for staging
postgres_node_type = "DB-DEV-M"
mongodb_node_type  = "MGDB-PLAY2-NANO"

# Compute sizing — moderate for staging
backend_min_scale       = 1
backend_max_scale       = 2
backend_cpu_limit       = 1000
backend_memory_limit    = 1024
biocompute_min_scale    = 1
biocompute_max_scale    = 2
biocompute_cpu_limit    = 2000
biocompute_memory_limit = 2048

# Feature flags
enable_monitoring         = true
enable_frontend_container = false

tags = ["tier:staging"]
