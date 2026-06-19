output "project_id" {
  description = "The sovereign Scaleway project the IAM domain is scoped to."
  value       = data.scaleway_account_project.sovereign.id
}

output "deploy_application_id" {
  value = scaleway_iam_application.deploy.id
}

output "deploy_access_key" {
  value     = scaleway_iam_api_key.deploy.access_key
  sensitive = true
}

output "deploy_secret_key" {
  value     = scaleway_iam_api_key.deploy.secret_key
  sensitive = true
}
