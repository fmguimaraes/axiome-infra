# Observability (FR9 / NFR8)

Two complementary layers:

1. **Portable stack** (this directory) — **Prometheus** (metrics), **Loki + Promtail**
   (logs), **Grafana** (dashboards/alerts). Runs as containers on the compute host on
   any provider, so there is **no AWS-only lock-in**. This is the reference stack and
   the **default log sink for on-prem** (connected and air-gapped).
2. **Provider-native log sinks** — now **implemented** per cloud provider so logs land
   in each provider's managed console without leaving its HDS French region (CONTRACT §1):

   | Provider | Native log sink | Agent on the VM | Wiring |
   |---|---|---|---|
   | AWS | CloudWatch Logs (`/axiome/<env>/ec2`, CMK-encrypted) | `amazon-cloudwatch-agent` | `providers/aws/modules/compute-ec2` + cloud-init step 13 |
   | Scaleway | Cockpit (managed Loki/Grafana) | Grafana Alloy | `providers/scaleway/modules/logging` + cloud-init step 10 |
   | OVH | Logs Data Platform (Graylog) | Fluent Bit / Alloy | `providers/ovh/modules/logging` — **design scaffold** (no OVH compute yet, AXI-953) |
   | On-prem | **this portable stack** (Loki/Promtail/Grafana) | Promtail | `providers/onprem/compose/docker-compose.logging.yml` |

Every agent **tails the json-file container logs** (the `json-file` driver is kept so
`docker logs` / `docker compose logs` still work for debugging) plus host bootstrap
logs — it never switches Docker to a cloud log-driver.

## Enable the portable stack

```
docker compose -f docker-compose.yml -f observability/docker-compose.observability.yml up -d
```

`GRAFANA_ADMIN_PASSWORD` and `ALERTMANAGER_RECEIVER_WEBHOOK_URL` are injected from the
secrets store at deploy time — never hard-coded. **No secrets or PII** may be shipped to
logs (NFR8); Promtail ships container stdout/stderr only (see `promtail-config.yml`).

## Alarms (FR12 / AC12)

`node-exporter` + `cadvisor` + `blackbox-exporter` feed `alerts.yml` (evaluated by
Prometheus) which pages via `alertmanager` → the on-call webhook configured in
`ALERTMANAGER_RECEIVER_WEBHOOK_URL` (PagerDuty/Opsgenie/Slack — any tool that accepts a
generic webhook):

| Signal (FR12) | Source | Rule |
|---|---|---|
| Disk capacity | `node-exporter` (host filesystem) | `DiskSpaceLow` |
| Container/service health | `up{job="axiome-services"}` + `cadvisor` restart counts | `ServiceDown`, `ContainerRestartingTooOften` |
| TLS-cert expiry | `blackbox-exporter` HTTPS probe of the public FQDN | `TLSCertExpiringSoon`, `HTTPSProbeFailed` |
| Backup success/failure | see below — not a Prometheus metric today | — |

**Backup failure** is wired at the provider level instead of here, because a Prometheus
metric would have nothing real to read yet: today only RDS has automated backups
(`backup_retention_period`, AWS `providers/aws/modules/alerting`, an
`aws_db_event_subscription` on the `backup` event category). Add a
`backup_last_success_timestamp` metric + `BackupJobFailed` rule here once a Mongo/EBS
backup job exists (AXI-113 / FR1).

A synthetic-condition test (raise an alert, e.g. fill `/tmp` past the threshold or stop
a service) is part of the manual-E2E plan (AXI-916, §4.4 / AC12).
