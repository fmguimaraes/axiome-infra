resource "scaleway_vpc_private_network" "main" {
  name   = "${var.naming_prefix}-private-network"
  region = var.region
  tags   = var.tags
}
