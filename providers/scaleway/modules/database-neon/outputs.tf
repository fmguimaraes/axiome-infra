output "connection_string" {
  value     = neon_project.axiome.connection_uri
  sensitive = true
}

output "host" {
  value     = neon_project.axiome.database_host
  sensitive = true
}
