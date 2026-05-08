output "fqdn" {
  value = var.fqdn
}

output "zone_id" {
  value = data.aws_route53_zone.primary.zone_id
}
