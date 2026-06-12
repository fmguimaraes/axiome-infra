output "primary_endpoint" {
  value = aws_elasticache_replication_group.this.primary_endpoint_address
}

output "port" {
  value = 6379
}

output "redis_url" {
  description = "rediss:// URL (TLS in transit). Wire into the gateway's REDIS_URL."
  value       = "rediss://${aws_elasticache_replication_group.this.primary_endpoint_address}:6379"
  sensitive   = true
}
