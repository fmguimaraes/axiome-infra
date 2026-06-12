output "key_arn" {
  value = aws_kms_key.data.arn
}

output "key_id" {
  value = aws_kms_key.data.key_id
}

output "alias_name" {
  value = aws_kms_alias.data.name
}
