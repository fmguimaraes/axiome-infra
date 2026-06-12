output "primary_endpoint" {
  value = local.primary_endpoint
}

output "redis_url" {
  value     = local.redis_url
  sensitive = true
}
