# Power operations — audit log

Append-only, versioned in git. One row per change made by `power.sh` (compute)
or `power-data.sh` (data tier). Timestamps are UTC. Written automatically by the
scripts' `log_event`; do not edit past rows.

| Timestamp (UTC) | Env | Resource | Change | Actor |
|---|---|---|---|---|
| 2026-08-13T00:00:00Z | production | EC2 i-0fce8b81eab806118 | compute stopped (test run; instance was already stopped) | arn:aws:iam::225201317100:user/axiome-terraform |
| 2026-08-13T09:38:52Z | production | EC2 i-0fce8b81eab806118 | compute stopped | arn:aws:iam::225201317100:user/axiome-terraform |
| 2026-08-13T09:38:59Z | production | RDS axiome-production-pg | available -> stopping (AWS auto-restarts after 7d) | arn:aws:iam::225201317100:user/axiome-terraform |
| 2026-08-13T09:39:05Z | production | Redis axiome-production-redis | snapshot axiome-production-redis-final-20260813-0939 taken, replication group deleting | arn:aws:iam::225201317100:user/axiome-terraform |
| 2026-08-20T08:37:09Z | production | RDS axiome-production-pg | stopped -> starting | arn:aws:iam::225201317100:user/axiome-terraform |
| 2026-08-20T08:39:42Z | production | Redis axiome-production-redis | recreating from snapshot axiome-production-redis-final-20260813-0939 | arn:aws:iam::225201317100:user/axiome-terraform |
| 2026-08-20T09:02:56Z | production | EC2 i-0fce8b81eab806118 | compute started, public health poll skipped, time-to-running 2s | arn:aws:iam::225201317100:user/axiome-terraform |
| 2026-08-20T09:03:04Z | production | platform | TURN-ON completed (data + compute up) | arn:aws:iam::225201317100:user/axiome-terraform |
| 2026-08-21T07:00:27Z | production | EC2 i-0fce8b81eab806118 | compute stopped | arn:aws:iam::225201317100:user/axiome-terraform |
| 2026-08-21T07:09:44Z | production | RDS axiome-production-pg | available -> stopping (AWS auto-restarts after 7d) | arn:aws:iam::225201317100:user/axiome-terraform |
| 2026-08-21T07:09:51Z | production | Redis axiome-production-redis | snapshot axiome-production-redis-final-20260821-0709 taken, replication group deleting | arn:aws:iam::225201317100:user/axiome-terraform |
| 2026-08-25T14:35:34Z | production | EC2 i-0fce8b81eab806118 | compute stopped | arn:aws:iam::225201317100:user/axiome-terraform |
| 2026-08-25T14:35:40Z | production | RDS axiome-production-pg | available -> stopping (AWS auto-restarts after 7d) | arn:aws:iam::225201317100:user/axiome-terraform |
| 2026-08-25T17:06:08Z | production | RDS axiome-production-pg | stopped -> starting | arn:aws:iam::225201317100:user/axiome-terraform |
| 2026-08-25T17:06:13Z | production | Redis axiome-production-redis | recreating from snapshot axiome-production-redis-final-20260821-0709 | arn:aws:iam::225201317100:user/axiome-terraform |
| 2026-08-25T17:16:22Z | production | EC2 i-0fce8b81eab806118 | compute started, time-to-up 58s | arn:aws:iam::225201317100:user/axiome-terraform |
| 2026-08-25T17:16:24Z | production | platform | TURN-ON completed (data + compute up) | arn:aws:iam::225201317100:user/axiome-terraform |
| 2026-08-25T21:31:43Z | production | EC2 i-0fce8b81eab806118 | compute stopped | arn:aws:iam::225201317100:user/axiome-terraform |
| 2026-08-25T21:31:49Z | production | RDS axiome-production-pg | available -> stopping (AWS auto-restarts after 7d) | arn:aws:iam::225201317100:user/axiome-terraform |
| 2026-08-25T21:31:55Z | production | Redis axiome-production-redis | snapshot axiome-production-redis-final-20260825-2131 taken, replication group deleting | arn:aws:iam::225201317100:user/axiome-terraform |
| 2026-08-26T04:17:50Z | production | RDS axiome-production-pg | stopped -> starting | arn:aws:iam::225201317100:user/axiome-terraform |
| 2026-08-26T04:17:55Z | production | Redis axiome-production-redis | recreating from snapshot axiome-production-redis-final-20260825-2131 | arn:aws:iam::225201317100:user/axiome-terraform |
| 2026-08-26T04:26:49Z | production | EC2 i-0fce8b81eab806118 | compute started, time-to-up 58s | arn:aws:iam::225201317100:user/axiome-terraform |
