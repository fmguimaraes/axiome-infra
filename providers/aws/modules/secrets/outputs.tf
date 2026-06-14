output "parameter_prefix" {
  value = local.prefix
}

output "lightsail_iam_role_arn" {
  value = try(aws_iam_role.lightsail_ssm[0].arn, "")
}

output "lightsail_iam_role_name" {
  value = try(aws_iam_role.lightsail_ssm[0].name, "")
}
