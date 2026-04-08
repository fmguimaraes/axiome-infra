output "registry_endpoint" {
  description = "Container registry endpoint URL"
  value       = scaleway_registry_namespace.main.endpoint
}

output "registry_id" {
  description = "Container registry namespace ID"
  value       = scaleway_registry_namespace.main.id
}
