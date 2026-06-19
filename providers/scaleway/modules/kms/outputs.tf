output "key_id" {
  description = "Scaleway Key Manager CMK id (used to encrypt data at rest)."
  value       = scaleway_key_manager_key.data.id
}

output "key_arn" {
  description = "Stable alias of key_id for the cross-provider output contract (Scaleway has no ARN)."
  value       = scaleway_key_manager_key.data.id
}
