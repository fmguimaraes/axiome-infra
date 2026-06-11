# OVH provider root — conforms to providers/CONTRACT.md.
#
# Foundation scaffold (AXI-951): provider config + naming locals + the common
# contract surface. Service modules (network, compute, storage, registry, secrets,
# database-neon, database-atlas, dns) are added by their owning stories — see
# CONTRACT.md §4. They are intentionally not yet instantiated so this root stays
# `terraform validate`-clean while the modules land.

provider "ovh" {
  endpoint = var.ovh_endpoint
  # Credentials via env: OVH_APPLICATION_KEY, OVH_APPLICATION_SECRET, OVH_CONSUMER_KEY.
}

locals {
  naming_prefix = "${var.project_name}-${var.environment}"
  fqdn          = "${var.subdomain}.${var.domain}"
  common_tags = concat(
    ["project:${var.project_name}", "env:${var.environment}"],
    var.tags,
  )
}
