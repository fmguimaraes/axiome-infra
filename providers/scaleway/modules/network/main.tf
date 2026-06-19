# Scaleway VPC + private network + 3-tier security groups (AXI-991 / FR1, NFR7, AC11).
# Default-deny ingress; only 80/443 public at the edge; data stores bind to the private
# network and never expose 0.0.0.0/0 to a data/broker/cache port (CONTRACT §5). Output
# contract mirrors the AWS network module so the root stays provider-agnostic (§4).

resource "scaleway_vpc" "this" {
  name   = "${var.naming_prefix}-vpc"
  region = var.scaleway_region
  tags   = var.tags
}

resource "scaleway_vpc_private_network" "this" {
  name   = "${var.naming_prefix}-net"
  vpc_id = scaleway_vpc.this.id
  region = var.scaleway_region
  tags   = var.tags
}

# Edge: the only group with public ingress, restricted to 80/443.
resource "scaleway_instance_security_group" "edge" {
  name                    = "${var.naming_prefix}-edge"
  description             = "Edge tier: only 80/443 from the internet"
  inbound_default_policy  = "drop"
  outbound_default_policy = "accept"

  inbound_rule {
    action   = "accept"
    protocol = "TCP"
    port     = 80
  }

  inbound_rule {
    action   = "accept"
    protocol = "TCP"
    port     = 443
  }
}

# App: no public ingress (reached from the edge over the private network).
resource "scaleway_instance_security_group" "app" {
  name                    = "${var.naming_prefix}-app"
  description             = "App tier: default-deny ingress; reached via the private network"
  inbound_default_policy  = "drop"
  outbound_default_policy = "accept"
}

# Data: default-deny. Postgres/Mongo/Redis/RabbitMQ bind to the private network only;
# never 0.0.0.0/0 to a data port (NFR7, AC11).
resource "scaleway_instance_security_group" "data" {
  name                    = "${var.naming_prefix}-data"
  description             = "Data tier: default-deny; data ports reachable only via the private network"
  inbound_default_policy  = "drop"
  outbound_default_policy = "accept"
}
