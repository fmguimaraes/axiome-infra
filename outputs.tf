output "private_network_id" {
  description = "ID of the private network"
  value       = module.network.private_network_id
}

output "backend_endpoint" {
  description = "Public endpoint for the backend service"
  value       = module.compute.backend_endpoint
}

output "biocompute_private_endpoint" {
  description = "Private endpoint for the biocompute service"
  value       = module.compute.biocompute_private_endpoint
}

output "frontend_url" {
  description = "URL for the frontend"
  value       = var.enable_frontend_container ? module.compute.frontend_endpoint : module.storage.frontend_bucket_url
}

output "postgres_host" {
  description = "Postgres connection host"
  value       = module.database.postgres_host
  sensitive   = true
}

output "postgres_port" {
  description = "Postgres connection port"
  value       = module.database.postgres_port
}

output "mongodb_host" {
  description = "MongoDB connection host"
  value       = module.database.mongodb_host
  sensitive   = true
}

output "mongodb_port" {
  description = "MongoDB connection port"
  value       = module.database.mongodb_port
}

output "artifacts_bucket" {
  description = "Object storage bucket for artifacts"
  value       = module.storage.artifacts_bucket_name
}

output "uploads_bucket" {
  description = "Object storage bucket for uploads"
  value       = module.storage.uploads_bucket_name
}

output "system_bucket" {
  description = "Object storage bucket for system files"
  value       = module.storage.system_bucket_name
}

output "registry_endpoint" {
  description = "Container registry endpoint"
  value       = module.registry.registry_endpoint
}
