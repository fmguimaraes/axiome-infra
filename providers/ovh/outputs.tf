# Common contract outputs (providers/CONTRACT.md §3).
# Foundation scaffold exposes the naming/identity outputs available pre-modules.
# Service outputs (public_ip, registry_endpoint, neon/atlas connection strings,
# s3_*) are added with their owning modules — see CONTRACT.md §4.

output "fqdn" {
  value = local.fqdn
}

output "naming_prefix" {
  value = local.naming_prefix
}

output "region" {
  description = "Chosen OVH region (HDS-certified French region per CONTRACT §1)."
  value       = var.ovh_region
}
