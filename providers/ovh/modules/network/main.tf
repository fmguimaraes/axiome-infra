# SCAFFOLD (OVH private network + firewall — FR1 / NFR7). Not tested yet; refine +
# validate before apply (planned 2026-06-12). OVH Public Cloud is OpenStack-based,
# so the security-group surface is typically created via the openstack provider
# alongside ovh_cloud_project_network_private.
#
# Intended implementation:
#
#   resource "ovh_cloud_project_network_private" "this" {
#     service_name = var.ovh_cloud_project_id
#     name         = "${var.naming_prefix}-net"
#     regions      = [var.ovh_region]
#   }
#   resource "ovh_cloud_project_network_private_subnet" "this" {
#     service_name = var.ovh_cloud_project_id
#     network_id   = ovh_cloud_project_network_private.this.id
#     region       = var.ovh_region
#     start        = "10.20.0.2"
#     end          = "10.20.0.254"
#     network      = "10.20.0.0/24"
#     dhcp         = true
#   }
#   # Security groups via the openstack provider:
#   #   openstack_networking_secgroup_v2 (edge / app / data)
#   #   data SG: ingress on var.data_ports ONLY from the app SG — never 0.0.0.0/0.
#
# Mirror the AWS network module's output contract (vpc_id, *_subnet_ids,
# *_security_group_id) so the root composition stays provider-agnostic (CONTRACT §4).

locals {
  vpc_id                 = null
  private_subnet_ids     = []
  public_subnet_ids      = []
  edge_security_group_id = null
  app_security_group_id  = null
  data_security_group_id = null
}
