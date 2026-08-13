# Change report — AWS power tooling (compute + data-tier park)

- **Date:** 2026-08-13
- **Branch:** `power-tooling` (axiome-infra)
- **Scope:** `providers/aws/scripts/`, `providers/aws/Makefile`, `providers/aws/docs/`, `reports/`
- **Environment observed:** production (account 225201317100, eu-west-3)

## What changed

Two scripts + Make wrappers + a versioned audit log to end by-hand
AWS-console toggling.

| File | Purpose |
|---|---|
| `providers/aws/scripts/power.sh` | Daily **compute** on/off. EC2 only; never storage. `up` measures time-to-up. |
| `providers/aws/scripts/power-data.sh` | Long-idle **data-tier** park. RDS stop/start; ElastiCache snapshot→delete→restore. |
| `providers/aws/Makefile` | `power-{status,up,down}` and `data-{status,down,up}` targets. |
| `providers/aws/docs/power-runbook.md` | Operating procedure, time-to-up record, CD-gating rules. |
| `reports/power-operations.md` | Append-only audit log; one row per operation. |

`REPORTS_DIR` resolves to the repo root of the running checkout via
`git rev-parse`, so the audit log is versioned with the code.

## Observed production state at authoring time

| Resource | Id | State | Note |
|---|---|---|---|
| EC2 compute | i-0fce8b81eab806118 (t3.medium) | stopped | platform offline (pre-launch) |
| RDS Postgres | axiome-production-pg (db.t3.micro, 20GB, single-AZ) | available | deletion_protection = true |
| ElastiCache Redis | axiome-production-redis (cache.t3.micro, 1 node) | available | SnapshotRetentionLimit = 0 (no auto backups) |

## Decisions / constraints honored

- **Stop compute, never storage** (power.sh). Data tier handled separately.
- **RDS = stop, not delete** — deletion_protection on; stop preserves endpoint.
  ⚠ AWS auto-restarts a stopped RDS after 7 days; the 10-day window needs a
  day-6 re-stop or accepts a few days of restarted billing.
- **ElastiCache = snapshot→delete→restore** — cannot be stopped. Config captured
  to S3; final snapshot taken before delete (no automatic backups exist).
- **terraform-cd must be gated** for the whole Redis down→up window.
- **Half a day, not a project** — scripts + runbook + Make targets; no Lambda /
  EventBridge orchestration layer.

## Verification

- `power.sh production down` + `status`: exercised against real prod EC2
  (already stopped) — idempotent, exited clean. Logged.
- `power-data.sh production status`: resolved real RDS + Redis.
- `power-data.sh production down`: **not yet executed** — blocked by the local
  safety classifier (destructive). Awaiting an authorized run + confirmation that
  terraform-cd is gated.

## Open items

- Confirm public health path for `power.sh up` (assumed `/api/v1/health/live`).
- Record first real `time-to-up` in the runbook.
- Run `data-down` for the ≥10-day park once CD is gated.
