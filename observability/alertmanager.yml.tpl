# Alertmanager routing (FR12). The receiver URL is injected at container start from
# ALERTMANAGER_RECEIVER_WEBHOOK_URL (secrets store — never hard-coded here; see
# docker-compose.observability.yml). Point it at whatever the on-call tool accepts a
# generic webhook for (PagerDuty/Opsgenie "Events API" webhook, Slack incoming webhook,
# Opsgenie/PagerDuty native Alertmanager integration URL, etc).
route:
  receiver: on-call
  group_by: ["alertname", "instance"]
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h

receivers:
  - name: on-call
    webhook_configs:
      - url: "__WEBHOOK_URL__"
        send_resolved: true
