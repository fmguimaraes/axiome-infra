locals {
  subdomain = trimsuffix(replace(var.fqdn, var.domain, ""), ".")
}

resource "scaleway_domain_record" "fqdn" {
  dns_zone = var.domain
  name     = local.subdomain
  type     = "A"
  data     = var.static_ip
  ttl      = 300
}
