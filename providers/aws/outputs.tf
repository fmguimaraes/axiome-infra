output "fqdn" {
  description = "Public FQDN of this environment (computed from subdomain + domain). DNS A record is created by Terraform only when use_route53 = true; otherwise configure it manually at the registrar."
  value       = local.fqdn
}

output "dns_managed_by_terraform" {
  description = "Whether the A record for fqdn is managed by Terraform (Route 53). When false, point fqdn at lightsail_static_ip manually at the registrar."
  value       = var.use_route53
}

output "lightsail_static_ip" {
  description = "Lightsail static IP for SSH and DNS"
  value       = module.compute.static_ip
}

output "lightsail_instance_name" {
  description = "Lightsail instance name (for SSH / management)"
  value       = module.compute.instance_name
}

output "ecr_registry_url" {
  description = "ECR registry URL (account-shared)"
  value       = module.registry.registry_url
}

output "neon_connection_string" {
  description = "Neon Postgres connection string (sensitive)"
  value       = module.database_neon.connection_string
  sensitive   = true
}

output "atlas_connection_string" {
  description = "Atlas MongoDB SRV connection string (sensitive)"
  value       = module.database_atlas.connection_string
  sensitive   = true
}

output "s3_artifacts_bucket" {
  description = "S3 artifacts bucket"
  value       = module.storage.artifacts_bucket_name
}

output "s3_uploads_bucket" {
  description = "S3 uploads bucket"
  value       = module.storage.uploads_bucket_name
}

output "s3_system_bucket" {
  description = "S3 system bucket"
  value       = module.storage.system_bucket_name
}

output "ssm_parameter_prefix" {
  description = "SSM Parameter Store prefix where runtime config is stored"
  value       = module.secrets.parameter_prefix
}
