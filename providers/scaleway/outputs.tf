output "fqdn" {
  value = local.fqdn
}

output "instance_id" {
  value = module.compute.instance_id
}

output "public_ip" {
  value = module.compute.public_ip
}

output "registry_endpoint" {
  value = module.registry.registry_endpoint
}

output "neon_connection_string" {
  value     = module.database_neon.connection_string
  sensitive = true
}

output "atlas_connection_string" {
  value     = module.database_atlas.connection_string
  sensitive = true
}

output "s3_endpoint" {
  value = module.storage.endpoint
}

output "s3_artifacts_bucket" {
  value = module.storage.artifacts_bucket_name
}

output "s3_uploads_bucket" {
  value = module.storage.uploads_bucket_name
}

output "s3_system_bucket" {
  value = module.storage.system_bucket_name
}
