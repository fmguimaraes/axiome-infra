output "connection_string" {
  value = format(
    "mongodb+srv://%s:%s@%s/axiome?retryWrites=true&w=majority",
    mongodbatlas_database_user.app.username,
    random_password.db_user.result,
    replace(mongodbatlas_advanced_cluster.axiome.connection_strings[0].standard_srv, "mongodb+srv://", "")
  )
  sensitive = true
}
