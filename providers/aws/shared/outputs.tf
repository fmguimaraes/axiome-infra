output "registry_url" {
  description = "ECR registry URL (account-shared)"
  value       = module.registry.registry_url
}

output "pull_role_arn" {
  description = "IAM role ARN used by legacy Lightsail compute to pull from ECR"
  value       = module.registry.pull_role_arn
}

output "pull_role_name" {
  description = "IAM role name used by legacy Lightsail compute to pull from ECR"
  value       = module.registry.pull_role_name
}

output "repository_urls" {
  description = "Map of service -> ECR repository URL"
  value       = module.registry.repository_urls
}
