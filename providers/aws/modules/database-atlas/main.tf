terraform {
  required_providers {
    mongodbatlas = {
      source = "mongodb/mongodbatlas"
    }
    random = {
      source = "hashicorp/random"
    }
  }
}

resource "mongodbatlas_project" "axiome" {
  name   = var.naming_prefix
  org_id = var.org_id
}

resource "random_password" "db_user" {
  length  = 32
  special = false
}

resource "mongodbatlas_database_user" "app" {
  project_id         = mongodbatlas_project.axiome.id
  username           = "axiome_app"
  password           = random_password.db_user.result
  auth_database_name = "admin"

  roles {
    role_name     = "readWrite"
    database_name = "axiome"
  }

  scopes {
    name = mongodbatlas_advanced_cluster.axiome.name
    type = "CLUSTER"
  }
}

# Lightsail static IP isn't known here; allow 0.0.0.0/0 (Atlas free tier requires
# explicit allowlist). For production, narrow to the Lightsail egress IP.
# Connection security relies on TLS + database user credentials.
resource "mongodbatlas_project_ip_access_list" "anywhere" {
  project_id = mongodbatlas_project.axiome.id
  cidr_block = "0.0.0.0/0"
  comment    = "Open access; auth via TLS + DB user. Tighten for production."
}

resource "mongodbatlas_advanced_cluster" "axiome" {
  project_id   = mongodbatlas_project.axiome.id
  name         = "${var.naming_prefix}-cluster"
  cluster_type = "REPLICASET"
  # M0 (tenant/Free) locks the MongoDB version — Atlas rejects any value, even matching the actual one.
  mongo_db_major_version = var.cluster_tier == "M0" ? null : var.mongo_version

  replication_specs {
    region_configs {
      provider_name         = var.cluster_tier == "M0" ? "TENANT" : var.cloud_provider
      backing_provider_name = var.cluster_tier == "M0" ? var.cloud_provider : null
      region_name           = var.region
      priority              = 7

      electable_specs {
        instance_size = var.cluster_tier
        node_count    = var.cluster_tier == "M0" ? null : 3
      }
    }
  }
}
