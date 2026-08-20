# Runbook — Power controls (`power.sh` + `power-data.sh`)

Cut the AWS bill on the low-traffic HDS environment without clicking the console.
Two scripts, two risk profiles. Both write a versioned audit row per change to
the repo-root `reports/power-operations.md` of the checkout they run from.

Invoke via Make (from `providers/aws/`, `ENV` defaults to `dev`):

```bash
make power-status ENV=production   # EC2 state
make power-down   ENV=production   # stop compute for the night
make power-up     ENV=production   # start compute; prints time-to-up
make data-status  ENV=production   # RDS + Redis state
make data-down    ENV=production   # long-idle park (destructive for Redis)
make data-up      ENV=production   # restore data tier
```

Or call the scripts directly: `scripts/power.sh <env> <up|down|status>`.

## One-call TURN-ON (validated) — `power-up-all.sh` / `make turn-on`

Bring a fully-parked environment **all the way back in one call**, in the correct
order, with preflight safety. This is the validated superset of the bare `make up`
(which just chains `data-up` + `power-up` with no checks).

```bash
# 1) Preflight / dry-run — read-only; makes NO changes. Prints AWS identity, the
#    live state of EC2/RDS/Redis, and verifies the Redis restore inputs exist.
make turn-on ENV=production
#    (equivalently: scripts/power-up-all.sh production)

# 2) Execute — same preflight, then data-up (RDS start + Redis restore, wait
#    healthy) -> power-up (EC2 start, health-gated, prints time-to-up).
make turn-on ENV=production YES=1
#    (equivalently: scripts/power-up-all.sh production --yes)
```

**What the turn-on validates (why this is also the turn-on *test*):**

1. **AWS access** — aborts if `sts get-caller-identity` fails.
2. **Restore inputs present** — when Redis is `absent`, it aborts *before any
   mutation* unless both the `redis-state.env` (`s3://<sys-bucket>/power-data/`)
   **and** the referenced final snapshot (`SnapshotStatus=available`) exist. That
   snapshot is the only copy of the Redis data — no snapshot, no run.
3. **Ordering** — data tier is brought up and waited-healthy **first**, then
   compute, so the app never starts against a cold DB/Redis.
4. **App readiness** — `power-up` blocks on `https://<fqdn>/api/v1/health/live`
   returning 200 through the public edge (CloudFront → Caddy → gateway) and records
   **time-to-up**. A stack that starts but never serves fails the run (non-zero).
5. **State re-adoption** — the run ends by telling you to confirm
   `terraform plan` shows **no changes** (Redis recreated with the same id/config)
   **before** un-gating terraform-cd.

**Safety gate:** the mutating path requires an explicit `YES=1` / `--yes` (or
`POWER_CONFIRM=1`); without it the command is a safe dry-run. Reports are written
and auto-committed exactly like the single-tier scripts (a consolidated
`…-turn-on.md` per run, plus the index row).

**‼ Keep terraform-cd gated for the whole run** (Redis is recreated outside
Terraform). Production `apply` is already manual (GitHub Environment approval) — do
not approve an apply until the post-run `terraform plan` is clean.

## Compute — daily (`power.sh`)

Stops/starts **only** the EC2 box; never RDS/ElastiCache/S3/state. The EBS root
volume (Mongo/Rabbit/local-Redis docker volumes) survives a stop, so no data
moves. On boot the enabled `axiome.service` systemd unit runs `docker compose up
-d` against images already on EBS — no ECR pull.

### Time-to-up — the commercial number

`up` blocks until `https://<fqdn>/api/v1/health/live` returns 200 (through
CloudFront → Caddy → gateway) and prints elapsed seconds; the value is also
logged to `reports/`.

- **Estimated ~2–4 min.** Instance start ~30–60 s, then gateway waits on RabbitMQ
  healthy (`start_period` 90 s) before it serves — so cold-start won't beat ~90 s.
- **Measured (fill in on first real run):**
  - `YYYY-MM-DD  production  up  ____ s`

> **Live window from ~25 Aug.** Emmanuel needs the platform live from ~25/08. If
> a demo or the *convention d'accueil* lands, cold-start latency is a commercial
> variable: bring compute up **before** a scheduled demo (it's ~2–4 min, not
> instant), and don't leave prod down overnight in this window unless someone can
> run `power-up` first.

## Data tier — long idle only (`power-data.sh`)

Separate script, separate risk. Use **only** for a multi-day park, never daily.

- **RDS** → `stop` / `start`. Never deleted (deletion_protection on prod).
  ⚠ **AWS auto-restarts a stopped RDS after 7 days.** For a ≥10-day window,
  re-run `data-down` around day 6, or accept ~3 days of restarted billing.
- **ElastiCache** → snapshot → delete → restore (cannot be stopped). `down` saves
  the live config to `s3://axiome-<env>-system/power-data/redis-state.env` and
  takes a final snapshot before deleting; `up` recreates from both. There are
  **no automatic backups** (`SnapshotRetentionLimit=0`), so that final snapshot is
  the only copy.

**Order at `up`:** data tier up **and healthy first**, then `power-up` the compute.

**‼ terraform-cd must be gated for the whole Redis down→up window.** The RG is
deleted outside Terraform; a CD apply mid-window recreates it empty (data loss)
and drifts state. After `up`, `terraform plan` should show **no changes** (same
id/config → re-adopted). Don't un-gate CD until that plan is clean.

## Reports — `reports/`

Every `down`/`up` writes **two** things automatically (`status` writes nothing):

1. **A per-run report** `reports/YYYY-MM-DD-HHMMSS-<env>-<op>.md` — self-contained:
   actor, region, before-state, actions taken (with snapshot ids / time-to-up),
   after-state, and any reminders. One file per operation.
2. **One index row** appended to `reports/power-operations.md` — a quick-scan
   trail (UTC timestamp, env, resource, change, IAM actor) across all runs.

Both are produced by `scripts/_power_lib.sh` (sourced by both scripts).
`REPORTS_DIR` resolves to the repo root of the checkout running the script (via
`git rev-parse`); override with `REPORTS_DIR=`.

**Auto-commit:** after writing, the script commits *just* the per-run report and
the index row to the current branch (pathspec-scoped, so unrelated staged work is
never swept in). Commit message: `reports: <env> <op> — <report-basename>`. Opt
out with `POWER_NO_COMMIT=1`; it silently skips if the checkout isn't a git repo.

## terraform-cd interaction

- **Compute:** safe without gating CD — the AWS provider doesn't manage instance
  power state, so `apply` over a stopped instance is a no-op.
- **Data tier:** gate CD (see above). Deleting the ElastiCache RG is a real
  resource deletion that `apply` would otherwise revert.

## Troubleshooting

- **`power-up` never READY:** instance running but stack not serving. On the box:
  `ssm-exec.sh <env> 'docker compose -f /opt/axiome/docker-compose.yml ps'`,
  `journalctl -u axiome.service`.
- **"expected exactly one instance":** a deploy is mid-replace (two VMs). Re-run.
- **`data-up` Redis recreate fails:** confirm the final snapshot exists
  (`aws elasticache describe-snapshots`) and the state file is present at
  `s3://axiome-<env>-system/power-data/redis-state.env`.
