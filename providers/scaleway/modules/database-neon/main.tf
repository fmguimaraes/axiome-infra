terraform {
  required_providers {
    neon = {
      source = "kislerdm/neon"
    }
  }
}

resource "neon_project" "axiome" {
  name      = var.naming_prefix
  region_id = var.region_id

  default_endpoint_settings {
    autoscaling_limit_min_cu = var.compute_min_cu
    autoscaling_limit_max_cu = var.compute_max_cu
    suspend_timeout_seconds  = var.autosuspend_seconds
  }

  history_retention_seconds = var.environment == "production" ? 604800 : 86400
}

resource "neon_branch" "main" {
  project_id = neon_project.axiome.id
  name       = "main"
}

resource "neon_role" "app" {
  project_id = neon_project.axiome.id
  branch_id  = neon_branch.main.id
  name       = "axiome_app"
}

resource "neon_database" "axiome" {
  project_id = neon_project.axiome.id
  branch_id  = neon_branch.main.id
  name       = "axiome"
  owner_name = neon_role.app.name
}
