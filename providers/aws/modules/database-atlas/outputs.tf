output "project_id" {
  value = mongodbatlas_project.axiome.id
}

output "cluster_name" {
  value = mongodbatlas_advanced_cluster.axiome.name
}

output "connection_string" {
  description = "MongoDB SRV connection string with credentials"
  value = format(
    "mongodb+srv://%s:%s@%s/axiome?retryWrites=true&w=majority",
    mongodbatlas_database_user.app.username,
    random_password.db_user.result,
    replace(mongodbatlas_advanced_cluster.axiome.connection_strings[0].standard_srv, "mongodb+srv://", "")
  )
  sensitive = true
}

output "username" {
  value = mongodbatlas_database_user.app.username
}
