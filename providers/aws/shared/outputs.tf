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

# ---------------- Knowledge content bucket (AXI-2798) ----------------
# What the sync tooling's data-store.json needs (FR67): bucket + region. The key
# scheme (sha256/<2 hex>/<sha256>, backup/) is a fixed convention, not a
# Terraform output.

output "knowledge_bucket_name" {
  description = "Knowledge content bucket name — the `bucket` value for data-store.json (FR67)."
  value       = module.knowledge_store.bucket_name
}

output "knowledge_bucket_region" {
  description = "Knowledge content bucket region — the `region` value for data-store.json (FR67)."
  value       = module.knowledge_store.bucket_region
}

output "knowledge_iam_user_name" {
  description = "The one dedicated knowledge-tooling IAM principal (O18). Create its access key by hand after apply; Terraform never creates or holds one."
  value       = module.knowledge_store.iam_user_name
}

output "knowledge_iam_user_arn" {
  description = "ARN of the knowledge-tooling IAM principal."
  value       = module.knowledge_store.iam_user_arn
}
