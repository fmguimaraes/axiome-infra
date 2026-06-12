output "endpoint" {
  value = local.endpoint
}

output "port" {
  value = local.port
}

output "db_name" {
  value = local.db_name
}

output "username" {
  value = local.username
}

output "connection_string" {
  value     = local.connection_string
  sensitive = true
}
