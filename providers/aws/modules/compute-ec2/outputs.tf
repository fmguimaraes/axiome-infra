output "public_ip" {
  description = "Elastic IP — point the Microsoft 365 A record (platform.axiomebio.com) here (FR7)."
  value       = aws_eip.main.public_ip
}

output "instance_id" {
  value = aws_instance.main.id
}

output "instance_role_arn" {
  description = "ARN of the EC2 instance-profile role. The principal AXI-1299 uses to assume a per-tenant role (modules/tenant) for per-job, tenant-scoped STS credentials (FR12)."
  value       = aws_iam_role.ssm.arn
}

output "security_group_id" {
  value = aws_security_group.instance.id
}

output "cloudwatch_log_group_name" {
  description = "CloudWatch Logs group receiving container + host logs (FR9)."
  value       = aws_cloudwatch_log_group.ec2.name
}
