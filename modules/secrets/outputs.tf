output "database_credentials_id" {
  description = "Secret ID for database credentials"
  value       = scaleway_secret.database_credentials.id
}

output "api_secrets_id" {
  description = "Secret ID for API secrets"
  value       = scaleway_secret.api_secrets.id
}

output "storage_credentials_id" {
  description = "Secret ID for storage credentials"
  value       = scaleway_secret.storage_credentials.id
}
