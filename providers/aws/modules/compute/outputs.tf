output "instance_name" {
  value = aws_lightsail_instance.main.name
}

output "static_ip" {
  value = aws_lightsail_static_ip.main.ip_address
}

output "instance_arn" {
  value = aws_lightsail_instance.main.arn
}

output "runtime_iam_user" {
  value = aws_iam_user.lightsail_runtime.name
}
