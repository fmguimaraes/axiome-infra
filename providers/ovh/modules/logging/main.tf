# SCAFFOLD (OVH Logs Data Platform — FR9 / NFR8). Not tested yet; refine + validate
# before apply. Mirrors the cross-provider logging contract: this is OVH's native sink,
# the peer of AWS CloudWatch Logs and Scaleway Cockpit. Logs stay in an HDS French
# region (GRA/SBG/RBX) per CONTRACT §1.
#
# OVH LDP (dbaas_logs) is a managed Graylog/OpenSearch platform. Shipping path:
#   1. A Graylog stream with a write token (X-OVH-TOKEN).
#   2. Grafana Alloy or Fluent Bit on the compute VM (added by AXI-953, when the OVH
#      compute module lands) tails the json-file container logs + host bootstrap logs
#      and ships them to the LDP GELF/LTSV TLS endpoint with that token.
#
# NOTE: OVH has no compute module instantiated yet (see providers/ovh/main.tf), so there
# is nothing to attach a shipper to — this module is design-only until AXI-953. It is a
# validate-clean scaffold (no live resources), consistent with the other OVH modules.
#
# Intended implementation:
#
#   resource "ovh_dbaas_logs_output_graylog_stream" "logs" {
#     service_name = var.ovh_ldp_service_name
#     title        = "${var.naming_prefix}-logs"
#     description  = "Axiome ${var.environment} container + host logs"
#     retention_id = var.ldp_retention_id            # an in-region retention policy
#   }
#
#   # A write token / GELF input the VM agent uses (X-OVH-TOKEN header):
#   #   ovh_dbaas_logs_input { engine = "FLOWGGER" / "LOGSTASH", stream_id = ... }
#   # Endpoint: gra<n>.logs.ovh.com (TLS GELF/LTSV), region-pinned per CONTRACT §1.
#
# Encryption in transit is TLS to the LDP endpoint; at rest the platform manages keys
# (record custody in the HDS report, FR13).

locals {
  # LDP GELF/LTSV TLS ingestion endpoint for the chosen French region.
  ldp_endpoint = "${lower(substr(var.ovh_region, 0, 3))}.logs.ovh.com"
  stream_title = "${var.naming_prefix}-logs"
}
