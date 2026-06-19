output "secret_ids" {
  description = "Map of runtime config key -> Scaleway Secret Manager secret id."
  value       = { for k, s in scaleway_secret.this : k => s.id }
}

output "path" {
  description = "Secret Manager path prefix for this environment."
  value       = "/${var.environment}/${var.naming_prefix}"
}
