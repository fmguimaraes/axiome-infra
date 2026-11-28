output "bucket_name" {
  description = "Knowledge content bucket name. This is the `bucket` value the sync tooling's `data-store.json` names (FR67)."
  value       = aws_s3_bucket.knowledge.id
}

output "bucket_arn" {
  description = "Knowledge content bucket ARN."
  value       = aws_s3_bucket.knowledge.arn
}

output "bucket_region" {
  description = "AWS region the bucket was created in. This is the `region` value `data-store.json` names (FR67)."
  value       = aws_s3_bucket.knowledge.region
}

output "iam_user_name" {
  description = "The one dedicated knowledge-tooling IAM principal (O18). No access key is created by Terraform — create it by hand after apply and wire it into an AWS CLI profile."
  value       = aws_iam_user.knowledge_tooling.name
}

output "iam_user_arn" {
  description = "ARN of the knowledge-tooling IAM principal."
  value       = aws_iam_user.knowledge_tooling.arn
}
