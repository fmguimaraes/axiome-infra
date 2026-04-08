output "artifacts_bucket_name" {
  description = "Artifacts bucket name"
  value       = scaleway_object_bucket.artifacts.name
}

output "artifacts_bucket_endpoint" {
  description = "Artifacts bucket endpoint"
  value       = scaleway_object_bucket.artifacts.endpoint
}

output "uploads_bucket_name" {
  description = "Uploads bucket name"
  value       = scaleway_object_bucket.uploads.name
}

output "uploads_bucket_endpoint" {
  description = "Uploads bucket endpoint"
  value       = scaleway_object_bucket.uploads.endpoint
}

output "system_bucket_name" {
  description = "System bucket name"
  value       = scaleway_object_bucket.system.name
}

output "system_bucket_endpoint" {
  description = "System bucket endpoint"
  value       = scaleway_object_bucket.system.endpoint
}

output "frontend_bucket_name" {
  description = "Frontend static hosting bucket name"
  value       = scaleway_object_bucket.frontend.name
}

output "frontend_bucket_url" {
  description = "Frontend static hosting website URL"
  value       = scaleway_object_bucket_website_configuration.frontend.website_endpoint
}
