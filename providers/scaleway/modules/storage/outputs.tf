output "endpoint" {
  value = "https://s3.${var.region}.scw.cloud"
}

output "artifacts_bucket_name" {
  value = scaleway_object_bucket.artifacts.name
}

output "uploads_bucket_name" {
  value = scaleway_object_bucket.uploads.name
}

output "system_bucket_name" {
  value = scaleway_object_bucket.system.name
}

output "access_key" {
  value     = scaleway_iam_api_key.vm_runtime.access_key
  sensitive = true
}

output "secret_key" {
  value     = scaleway_iam_api_key.vm_runtime.secret_key
  sensitive = true
}
