output "push_url" {
  description = "Cockpit Loki push endpoint for the logs data source."
  value       = scaleway_cockpit_source.logs.push_url
}

output "token" {
  description = "Write-only Cockpit token for the Alloy log shipper (X-Token header)."
  value       = scaleway_cockpit_token.logs.secret_key
  sensitive   = true
}
