output "replication_group_id" {
  description = "ElastiCache replication group ID — used to scope CloudWatch alarms (FR12)."
  value       = aws_elasticache_replication_group.this.replication_group_id
}

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
