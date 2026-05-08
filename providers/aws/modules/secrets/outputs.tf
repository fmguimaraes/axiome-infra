output "parameter_prefix" {
  value = local.prefix
}

output "lightsail_iam_role_arn" {
  value = aws_iam_role.lightsail_ssm.arn
}

output "lightsail_iam_role_name" {
  value = aws_iam_role.lightsail_ssm.name
}
