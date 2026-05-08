data "aws_route53_zone" "primary" {
  name         = var.domain
  private_zone = false
}

resource "aws_route53_record" "fqdn" {
  zone_id = data.aws_route53_zone.primary.zone_id
  name    = var.fqdn
  type    = "A"
  ttl     = 300
  records = [var.static_ip]
}
