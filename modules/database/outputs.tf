output "postgres_host" {
  description = "Postgres instance host"
  value       = scaleway_rdb_instance.postgres.load_balancer[0].ip
  sensitive   = true
}

output "postgres_port" {
  description = "Postgres instance port"
  value       = scaleway_rdb_instance.postgres.load_balancer[0].port
}

output "postgres_instance_id" {
  description = "Postgres instance ID"
  value       = scaleway_rdb_instance.postgres.id
}

output "mongodb_host" {
  description = "MongoDB instance host"
  value       = scaleway_mongodb_instance.main.id
  sensitive   = true
}

output "mongodb_port" {
  description = "MongoDB default port"
  value       = 27017
}

output "mongodb_instance_id" {
  description = "MongoDB instance ID"
  value       = scaleway_mongodb_instance.main.id
}
