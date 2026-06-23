# Cross-provider logging contract surface (peer of AWS/Scaleway logging module outputs).
# Values are design-time placeholders until LDP + compute land (AXI-953).

output "endpoint" {
  description = "LDP GELF/LTSV TLS ingestion endpoint (region-pinned)."
  value       = local.ldp_endpoint
}

output "stream_title" {
  description = "Graylog stream title that will receive container + host logs."
  value       = local.stream_title
}
