output "policy_id" {
  description = "DLM lifecycle policy ID — used for status checks during the rebuild drill"
  value       = aws_dlm_lifecycle_policy.root_volume.id
}

output "dlm_role_arn" {
  description = "ARN of the IAM role assumed by DLM to manage snapshots"
  value       = aws_iam_role.dlm.arn
}
