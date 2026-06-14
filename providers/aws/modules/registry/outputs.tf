output "registry_url" {
  description = "ECR registry URL (account-shared)"
  value       = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${data.aws_region.current.name}.amazonaws.com"
}

output "pull_role_arn" {
  value = try(aws_iam_role.ecr_pull[0].arn, null)
}

output "pull_role_name" {
  value = try(aws_iam_role.ecr_pull[0].name, null)
}

output "repository_urls" {
  description = "Map of service -> ECR repo URL"
  value = {
    for k, v in aws_ecr_repository.axiome : k => v.repository_url
  }
}
