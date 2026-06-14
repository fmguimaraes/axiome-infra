output "fqdn" {
  description = "Public FQDN of this environment (computed from subdomain + domain). DNS A record is created by Terraform only when use_route53 = true; otherwise configure it manually at the registrar."
  value       = local.fqdn
}

output "dns_managed_by_terraform" {
  description = "Whether the A record for fqdn is managed by Terraform (Route 53). When false, point fqdn at lightsail_static_ip manually at the registrar."
  value       = var.use_route53
}

output "lightsail_static_ip" {
  description = "Lightsail static IP for SSH and DNS. null once use_legacy_stack = false."
  value       = try(module.compute[0].static_ip, null)
}

output "lightsail_instance_name" {
  description = "Lightsail instance name. null once use_legacy_stack = false."
  value       = try(module.compute[0].instance_name, null)
}

output "ecr_registry_url" {
  description = "ECR registry URL (account-shared)"
  value       = module.registry.registry_url
}

output "neon_connection_string" {
  description = "Neon Postgres connection string (sensitive). null when use_legacy_stack = false."
  value       = try(module.database_neon[0].connection_string, null)
  sensitive   = true
}

output "atlas_connection_string" {
  description = "Atlas MongoDB SRV connection string (sensitive). null when use_legacy_stack = false."
  value       = try(module.database_atlas[0].connection_string, null)
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

# ---------------- HDS data stack outputs (use_hds_data_stack / use_ec2_compute) ----------------

output "ec2_public_ip" {
  description = "Elastic IP of the EC2 compute. Point the Microsoft 365 A record (platform.axiomebio.com) at this (FR7). null until use_ec2_compute = true."
  value       = try(module.compute_ec2[0].public_ip, null)
}

output "rds_endpoint" {
  description = "RDS Postgres endpoint host. null until use_hds_data_stack = true."
  value       = try(module.database_rds[0].endpoint, null)
}

output "redis_endpoint" {
  description = "ElastiCache primary endpoint. null until use_hds_data_stack = true."
  value       = try(module.cache_redis[0].primary_endpoint, null)
}

# ---------------- Edge outputs (only populated when use_cloudfront_edge = true) ----------------

output "cloudfront_domain_name" {
  description = "CloudFront distribution domain. After ACM validates, create a CNAME at the registrar: <fqdn> -> this value (replacing the prior A record pointing at lightsail_static_ip)."
  value       = try(module.edge[0].cloudfront_domain_name, null)
}

output "cloudfront_distribution_id" {
  description = "CloudFront distribution ID — useful for cache invalidations."
  value       = try(module.edge[0].cloudfront_distribution_id, null)
}

output "acm_certificate_arn" {
  description = "ARN of the edge ACM certificate (us-east-1)."
  value       = try(module.edge[0].acm_certificate_arn, null)
}

output "acm_validation_records" {
  description = "DNS records to add at the registrar for ACM validation (paste into Microsoft 365)."
  value       = try(module.edge[0].acm_validation_records, [])
}
