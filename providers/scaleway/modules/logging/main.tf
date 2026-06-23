# Native log sink for Scaleway — Cockpit (managed Grafana + Loki), FR9 / NFR8.
# A "logs" data source plus a write-only token. The compute VM runs Grafana Alloy
# (see cloud-init) which ships container stdout/stderr + host bootstrap logs to the
# source's Loki push endpoint using the token in an X-Token header.
#
# Cockpit lives in the project's region (fr-par) — logs stay in-region per CONTRACT §1.
# Retention is enforced by the data source per CONTRACT (no out-of-region copy).

resource "scaleway_cockpit_source" "logs" {
  name           = "${var.naming_prefix}-logs"
  type           = "logs"
  retention_days = var.log_retention_days
  region         = var.scaleway_region
}

# Write-only token (least privilege — only write_logs). Used by Alloy on the VM.
resource "scaleway_cockpit_token" "logs" {
  name   = "${var.naming_prefix}-logs-writer"
  region = var.scaleway_region

  scopes {
    write_logs = true
  }
}
