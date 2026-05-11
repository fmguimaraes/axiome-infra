output "project_id" {
  value = neon_project.axiome.id
}

output "branch_id" {
  value = neon_project.axiome.default_branch_id
}

output "database_name" {
  value = neon_database.axiome.name
}

output "role_name" {
  value = neon_role.app.name
}

output "connection_string" {
  description = "Postgres connection string with credentials"
  value       = neon_project.axiome.connection_uri
  sensitive   = true
}

output "host" {
  value     = neon_project.axiome.database_host
  sensitive = true
}
