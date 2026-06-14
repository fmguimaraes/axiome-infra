output "public_ip" {
  description = "Elastic IP — point the Hostinger A record (platform.axiomebio.com) here (FR7)."
  value       = aws_eip.main.public_ip
}

output "instance_id" {
  value = aws_instance.main.id
}

output "security_group_id" {
  value = aws_security_group.instance.id
}
