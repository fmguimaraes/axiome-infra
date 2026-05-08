output "registry_endpoint" {
  value = scaleway_registry_namespace.main.endpoint
}

output "registry_namespace_id" {
  value = scaleway_registry_namespace.main.id
}

output "pull_secret_key" {
  value     = scaleway_iam_api_key.registry_pull.secret_key
  sensitive = true
}
