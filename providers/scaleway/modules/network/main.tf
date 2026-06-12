# SCAFFOLD (Scaleway VPC + private network + security group — FR1 / NFR7). Not
# tested yet; refine + validate before apply (planned 2026-06-12).
#
# Intended implementation:
#
#   resource "scaleway_vpc" "this" {
#     name   = "${var.naming_prefix}-vpc"
#     region = var.scaleway_region
#   }
#   resource "scaleway_vpc_private_network" "this" {
#     name   = "${var.naming_prefix}-net"
#     vpc_id = scaleway_vpc.this.id
#     region = var.scaleway_region
#   }
#   resource "scaleway_instance_security_group" "data" {
#     name                   = "${var.naming_prefix}-data"
#     inbound_default_policy  = "drop"   # default-deny (NFR7)
#     outbound_default_policy = "accept"
#     # inbound rules: var.data_ports reachable only from the app SG / private net
#     # — never 0.0.0.0/0.
#   }
#
# Mirror the AWS network module's output contract so the root stays
# provider-agnostic (CONTRACT §4).

locals {
  vpc_id                 = null
  private_subnet_ids     = []
  public_subnet_ids      = []
  edge_security_group_id = null
  app_security_group_id  = null
  data_security_group_id = null
}
