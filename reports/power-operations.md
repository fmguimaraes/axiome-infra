# Power operations — audit log

Append-only, versioned in git. One row per change made by `power.sh` (compute)
or `power-data.sh` (data tier). Timestamps are UTC. Written automatically by the
scripts' `log_event`; do not edit past rows.

| Timestamp (UTC) | Env | Resource | Change | Actor |
|---|---|---|---|---|
| 2026-08-13T00:00:00Z | production | EC2 i-0fce8b81eab806118 | compute stopped (test run; instance was already stopped) | arn:aws:iam::225201317100:user/axiome-terraform |
