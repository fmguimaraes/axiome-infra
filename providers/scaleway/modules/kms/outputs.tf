output "key_arn" {
  description = "CMK ARN/URN (null until the scaffold resources are enabled)."
  value       = local.key_arn
}

output "key_id" {
  value = local.key_id
}
