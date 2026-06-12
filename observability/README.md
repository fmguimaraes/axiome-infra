# Observability (FR9 / NFR8)

Portable, provider-agnostic stack — **Prometheus** (metrics), **Loki + Promtail**
(logs), **Grafana** (dashboards/alerts). Runs as containers on the compute host on
any provider, so there is **no AWS-only lock-in**. Provider-native sinks (CloudWatch
/ Scaleway Cockpit / OVH Logs Data Platform) are **optional** and may be added per
provider without changing the app.

## Enable

```
docker compose -f docker-compose.yml -f observability/docker-compose.observability.yml up -d
```

`GRAFANA_ADMIN_PASSWORD` is injected from the secrets store at deploy time — never
hard-coded. **No secrets or PII** may be shipped to logs (NFR8); Promtail ships
container stdout/stderr only.

## Alarms

Define basic alerts in Grafana (or Prometheus rules): service-down, high error rate,
disk/CPU saturation. A synthetic-condition test (raise an alert) is part of the
manual-E2E plan (AXI-916, §4.4 / AC12).
