# Platform Lifecycle Operations Runbook (FR41, NFR9, AC33)

Operator-facing runbook for everything epic AXI-1944 shipped: the migration
gate, deploy, roll, box conversion, baselining, locks, park/unpark, local
stack safety, and what the next Terraform apply will change. Every command,
flag, exit code and refusal message below is copied or paraphrased from the
actual script on `origin/main` as of this writing, not guessed — where a
refusal string is quoted it is verbatim; where it is paraphrased that is
called out. **Nothing in this runbook has been run against live AWS** — see
[Known gaps](#9-known-gaps) at the end.

For the migration-authoring rules (what makes a migration the gate accepts),
see [`migration-authoring-guide.md`](migration-authoring-guide.md).

---

## 0. Pre-flight — before touching any of this

- **AWS CLI version.** `scripts/lock.sh` needs **≥ 2.17.34** for atomic lock
  acquisition (`s3api put-object --if-none-match '*'`) — below that, `acquire`
  refuses with `ERROR: aws CLI … is older than the minimum 2.17.34 …`. It
  needs **≥ 2.22.3** for a conditional `release`/`override` delete
  (`--if-match <etag>`); below that, release/override WARN and fall back to
  an unconditional delete (a narrow, documented race window — see
  [§4 Locks](#4-locks)). If the version cannot be determined at all, `acquire`
  prints a WARNING and still tries the call — an old CLI that gets past the
  warning still cannot silently overwrite (it hits the "unsupported option"
  branch and fails, never falls back to an unconditional create).
- **GNU `date` is required** on whatever machine runs `power-data.sh` /
  `scripts/lock.sh` (age/duration calculations use `date -u -d <iso>`). A
  non-GNU `date` (e.g. macOS's BSD `date` without `coreutils`) makes those
  calculations come back empty and the affected function reports "unknown"
  rather than guessing — it fails safe, it does not silently miscompute.
- **`jq` is required** by `ssm-exec.sh`, `lock.sh`, and `power.sh`'s backup
  verification — each refuses immediately with a plain `ERROR: jq is
  required` if it is missing.
- **Shellcheck version skew (local vs CI):** CI's `infra-tests` job runs
  shellcheck **0.9.0**; a contributor's machine may have a newer version
  (0.11.0 as of this story). A file clean locally can still fail CI — known
  example: SC2120/SC2119 on a function that reads a positional parameter with
  a default but is never called with an argument. When adding new shell,
  avoid optional positional parameters nobody actually passes anywhere
  (including in tests/fixtures), and never add a disable directive or touch
  `tests/shellcheck-baseline.json` to get past a version-specific finding —
  write the function so neither version flags it.

---

## 1. One-time box conversion (AXI-1950)

**An existing box does not get the migration gate from a Terraform apply or a
reboot alone.** Its systemd unit (`axiome.service`) keeps running a bare
`docker compose up -d` — no asset sync, no `.env` refresh, no `migrate`
one-shot — until this one-time conversion is done, once, per box:

```bash
# 1. Pull the on-box asset bundle (compose file + boot.sh + asset-sync.sh +
#    refresh-env.sh + manifest) from the published S3 prefix into /opt/axiome:
scripts/asset-sync.sh pull s3://<project>-<env>-system/onbox /opt/axiome

# 2. Point the systemd unit at the new boot wrapper instead of a bare
#    `docker compose up -d` (do this on the box, over SSM/SSH):
#    ExecStart=/opt/axiome/scripts/boot.sh
# 3. Reload the unit:
systemctl daemon-reload
```

This has **never been run against a real box** — it is the documented,
reviewed path, not a verified one. `scripts/deploy-prod.sh`'s own preflight
names exactly this command when it detects an unconverted box (see
[§5 Deploy](#5-deploy)).

**What refuses until this is done, and why:**

| Operation | Refusal | Why |
|---|---|---|
| `scripts/roll-service.sh` (backend) | `REFUSE: <compose-file> has no 'migrate' service under services: — this box predates the migration gate. Run: scripts/asset-sync.sh pull <s3-prefix> <dir> on this box, then retry the roll.` | No `migrate` service in the box's compose file means `up -d` cannot run the gate at all before swapping backend containers — the script refuses rather than start backend containers unguarded. |
| `scripts/deploy-prod.sh` | `REFUSE: <env> box has no 'migrate' service in its compose definition — it predates the AXI-1950 asset-sync conversion. Run the one-time conversion: scripts/asset-sync.sh pull s3://<project>-<env>-system/onbox /opt/axiome on the box, point axiome.service at scripts/boot.sh, systemctl daemon-reload, then retry this deploy.` | Same check, read-only, at preflight time — before any snapshot or roll. |

`asset-sync.sh pull` itself (exit codes, for diagnosing a failed conversion):
`0` installed or already current; `2` manifest or a listed file unreachable
(existing assets kept); `3` a downloaded file's checksum did not match the
manifest (nothing installed); `4` the downloaded `docker-compose.yml` failed
`docker compose config -q` validation (nothing installed); `1` usage error.
Every non-zero exit leaves the destination directory untouched — a failed
pull never leaves a half-installed box.

Once converted, `boot.sh` runs on every boot: asset sync → `.env` refresh
(both **non-fatal** — a box with assets/`.env` already on disk still comes
up even if S3/SSM is unreachable) → `docker compose up -d` (this step's exit
code **is** `boot.sh`'s own exit code — the migrate-gate one-shot inside it
is never bypassed or swallowed).

---

## 2. Baselining — `migrate-gate baseline <service>`

**When it is the right action:** a service has real tables in its database
but **no Prisma migration ledger at all** (or an empty one) — e.g. a database
that was `db push`ed into existence once, long before the gate existed, or a
genuinely fresh schema that was never run through `migrate deploy`.
`migrate-gate apply`'s own classification step is what actually detects this
and prints the line that names it:

```
REFUSE <service>: tables exist with no migration ledger. Run: migrate-gate baseline <service>
```

Baselining then runs `prisma migrate resolve --applied <name>` once per
already-shipped migration directory, confirming **zero drift** before
recording each one as applied — per the AXI-1946 learnings log (the gate's
own source, `axiome-back docker/migrate-gate/`, is a different repo from
this one — these lines are not independently verifiable from
`axiome-infra` alone) it prints `Checking drift for <service> against its
configured datasource`, then one `resolve --applied <name>` line per
migration, then `Baseline complete for <service>: <n> migration(s) recorded
as applied (zero drift confirmed).` Measured once (throwaway
Postgres, built image): **organization-service ≈ 5–6.5 minutes** for 227+13
migrations (resumable if interrupted) — this is a several-minute, one-off
operator act, never put in a boot or deploy path.

**When it is NOT the right action — do not baseline a connectivity/config
failure.** `migrate-gate status` exits non-zero for exactly three reasons,
and only one of the three is remotely baseline-shaped:

- `not_configured` — a service listed in `MIGRATE_GATE_SERVICES` has no
  database URL set (`ORGANIZATION_DATABASE_URL` / `USER_DATABASE_URL`).
- `missing_migration_files` — the image's own migrations directory could not
  be read.
- `status_undetermined` — the status query itself threw (e.g. the database is
  unreachable right now).

**None of these three is "tables exist with no ledger"** — that classification
only exists in `apply`'s own classify step, which a read-only `status` call
never runs (running `apply` to find out would mutate any OTHER
already-ready service). `scripts/deploy-prod.sh`'s preflight therefore
distinguishes the two cases explicitly: if its own read of `migrate-gate
status`'s output happens to carry a literal `REFUSE <svc>: tables exist with
no migration ledger` line, it names that service's `baseline` command; for
every OTHER non-zero `status` exit it prints:

```
REFUSE: migrate-gate status could not be determined on the <env> box (exit <n>)
— this is a configuration or connectivity problem (e.g. a service's database
URL not set, or the database unreachable from inside the migrate container),
NOT evidence that any service needs baselining. Do NOT run migrate-gate
baseline unless the raw output below explicitly names a service with tables
and no ledger. Check both database URLs are present and reachable from the
migrate container, then retry.
```

Baselining a service that is merely unreachable right now would record
migrations as "applied" against a ledger the operator never actually
verified against — silently diverging the production ledger from reality.
**Read the raw output before ever running `baseline`.**

**A ledger-less service passes deploy preflight and is refused by `apply` at
roll time instead (AXI-1954 known gap).** `status`'s own exit-0 contract
folds a missing ledger into "every shipped migration is pending" — it does
not surface the `REFUSE … tables exist with no migration ledger` line unless
`apply`'s classify step produced it, which a read-only preflight never runs.
So a production deploy's preflight can show `PENDING_COUNT=<n>` and proceed
to snapshot + roll, and only the roll's own `migrate-gate apply` (inside the
`migrate` one-shot, with the OLD containers still serving) actually hits the
REFUSE and fails closed — the deploy then restores the previous tag per
§5's failure handling. **If you know a service is ledger-less, baseline it
BEFORE scheduling a deploy** — do not rely on preflight to catch it.

---

## 3. Deploy (`scripts/deploy-prod.sh` / `make deploy-prod`)

```bash
make deploy-prod ENV=production TAG=<8-char-sha>                      # backend (default)
make deploy-prod ENV=production TAG=<sha> SERVICE=frontend|biocompute
make deploy-prod ENV=production TAG=<sha> DRY_RUN=1                   # plan only, no mutation
# equivalently: scripts/deploy-prod.sh --tag <sha> [--env production] [--service backend] [--dry-run]
```

**Sequence (`AXI-1954`, re-ordered from the earlier AXI-1349 flow to close
H2/H6/H7 from the feature doc):**

1. Confirm the `data-tier` lock is free (`lock_require_free … data-tier`);
   refuse closed if held or UNKNOWN.
2. Acquire the `deploy` lock (auto-released on exit, even on Ctrl-C).
3. Preflight: verify the source tag exists in ECR and resolve its digest;
   read-only on-box check of `.env`'s prior tag, compose `migrate:` service
   presence, and `migrate-gate status` (§2 above governs how its result is
   read). The ONLY non-zero SSM exit here (box unreachable) is itself a
   refusal — nothing has mutated yet.
4. **Re-check** the `data-tier` lock (narrows, does not close, a race where a
   park starts between step 1 and here — see [§4](#4-locks)).
5. **Pre-deploy RDS snapshot** — backend, pending migrations, production
   only. Named `<project>-<env>-predeploy-<UTC timestamp>`; waits for
   `available` before continuing; pruned to the newest `SNAPSHOT_RETENTION`
   (default 5, manual snapshots with that prefix only) afterward. **Not
   taken** for frontend/biocompute (no schema, EC13) or when nothing is
   pending or off production.
6. **Roll** to the new tag via `roll-service.sh` over `ssm-exec.sh` — the OLD
   containers keep serving while the gate runs against the NEW image (the
   compose `migrate:` dependency, §1). This run's `MIGRATION_FACTS`/
   `MIGRATION_FACTS_OVERRIDE` lines are captured into the deploy report; an
   unavailable-facts result is a **warning only** here (the containers are
   already proven serving by the NEXT step), not a deploy failure.
7. **Readiness poll** — backend polls `/api/v1/health/ready` (JSON body,
   `services[].reason`); frontend/biocompute poll their own 2xx path.
8. **Advance `:stable`** — the LAST mutation, and only on readiness PASS. Also
   re-resolves the tag's digest right before retagging and refuses if it
   moved during the deploy (see "`:stable` not advanced" below).
9. **Read-only baseline verification** (`seed-environment.sh --check`,
   backend only) — warning only, **never** rolls back.
10. Release the `deploy` lock.

**Every refusal and what it means:**

| Stage | Refusal (paraphrased unless quoted) | Meaning |
|---|---|---|
| Locks | data-tier lock held/UNKNOWN | refuse before any mutation — a park may be in progress |
| Locks | `FAIL-CLOSED: could not acquire the deploy lock for <env> — another deploy or power operation is in progress.` | another deploy already running |
| Preflight (box) | `FAIL-CLOSED: could not reach <env> over SSM to preflight-check (INDETERMINATE) — the box may be stopped. Nothing has been changed.` | SSM wait expired (exit 2) — nothing mutated |
| Preflight (box) | `FAIL-CLOSED: /opt/axiome/.env does not exist on the <env> box — has cloud-init finished?` | box never finished first boot |
| Preflight (gate) | §1's box-conversion REFUSE, or §2's ledger/connectivity REFUSE | see §1/§2 |
| Post-preflight lock race | `FAIL-CLOSED: the data-tier lock for <env> is now held (parked during preflight) — refusing to snapshot/roll against it.` | a park started mid-preflight |
| Snapshot | `FAIL-CLOSED: could not create pre-deploy snapshot … — stopping before any migration.` / did not become available | RDS snapshot API failure or timeout — stop before migrating |
| Roll (indeterminate, exit 2) | `FAIL-CLOSED: the roll result is INDETERMINATE … :stable was NOT advanced.` | SSM wait expired on the roll itself; box state truly unknown — **no blind restore attempted** (see below) |
| Roll (failed, exit 1) | `FAIL-CLOSED: <env>/<service> roll failed — migration gate did not pass. :stable was never advanced.` | gate refused on the new image; previous tag is restored (see below) |
| Readiness | `FAIL-CLOSED: <env>/<service> did not become ready after <n> attempts.` + per-service reasons | readiness never reached 200; previous tag is restored |
| `:stable` advance | `FAIL-CLOSED: … advancing ECR :stable FAILED. Production is serving a build that :stable does NOT point at — retry … by hand with the digest …` | the box IS healthy on the new image, but the retag call itself failed — manual retag needed |
| `:stable` not advanced (digest moved) | `<repo>:<tag> moved during this deploy — it now points at <digest>, not the <digest> this deploy rolled out and verified ready. Refusing to advance :stable to a digest this deploy never proved healthy.` | someone re-pushed the mutable tag mid-deploy; the roll itself already succeeded and is healthy — only the `:stable` pointer is withheld |

**Restore behaviour (previous-tag restore):** on a roll failure (exit 1) or a
readiness failure, `deploy-prod.sh` re-rolls the box to `PRIOR_TAG` (captured
at preflight) via the SAME `roll-service.sh`, then polls health again to
confirm the restore itself worked, before reporting `failed-roll-restored` /
`failed-readiness-restored`. If the restore ALSO fails, it says so plainly
and names the manual recovery command
(`KEY=<key> IMAGE_TAG=<prior> SERVICE=<service> scripts/roll-service.sh`
by hand on the box) — `:stable` is untouched either way.

**On an INDETERMINATE roll (exit 2), there is deliberately NO automatic
restore** — the remote command was cancelled after its wait expired and its
true final state is unknown; blindly re-rolling an unknown state is not
safer than leaving it alone. The operator is told to check `docker compose
ps`, `docker compose logs migrate`, and the `.env` tag by hand before
retrying anything.

**"Schema may be ahead of the restored image" / "snapshot is the rollback
point":** every restore path above reports one of two statements, because a
restore re-points the BOX but never reverts the DATABASE SCHEMA the gate
already wrote:

- *Confirmed ahead:* "The migration gate completed successfully before this
  failure — the schema is now fully migrated, and the restored (older)
  image's own schema expectations predate this migration; restoring the box
  does NOT undo the schema change." (readiness-failure path — the gate had
  already passed).
- *Unknown:* "Migrations may have PARTIALLY applied before this failure (the
  gate stops at the first failing migration within a service, not before
  it) — the schema's true state relative to the restored (older) image is
  UNKNOWN." (roll-failure / indeterminate paths).

Either way, if a pre-deploy snapshot was taken, the message names it as "the
point-in-time rollback path if the schema needs to be reverted — this script
does NOT restore it automatically" — restoring a snapshot is always a human
decision, never automated here. If no snapshot was taken (frontend/
biocompute, or nothing was pending), the message says plainly there is no
automatic rollback path available.

**`:stable` not advanced, summarised — every case:** roll failed; roll
indeterminate; readiness failed; the retag call itself failed (box IS
healthy, pointer is stuck — needs a manual retag); the tag's digest moved
mid-deploy (box IS healthy, pointer deliberately withheld). In every one of
these, the thing that actually serves traffic and the thing `:stable` names
can disagree — check both independently (`docker compose ps` on the box vs.
`aws ecr describe-images --image-ids imageTag=stable`) before assuming either.

**`Baseline verification: NOT PERFORMED`:** `seed-environment.sh --check`
exits `3` (distinct from `0` match / nonzero mismatch) specifically when
expected counts cannot be derived — in `deploy-production.yml` this is
**always** the case today, because that workflow checks out only
`axiome-infra` (the expected-counts source lives in `axiome-back`). This is
reported as `Baseline verification: NOT PERFORMED`, never as a mismatch —
treating "could not check" as "checked and it's wrong" would be a false
alarm. Either way this step is warning-only and never rolls back.

---

## 4. Locks

**Inspect:**

```bash
scripts/lock.sh <dev|staging|production> status              # both locks
scripts/lock.sh <dev|staging|production> status deploy        # one lock
```

Output is `<name>: FREE` or `<name>: HELD by <actor> running <operation>
since <iso> (age <n>s) host=<host>`, or `<name>: UNKNOWN (<reason>)` — UNKNOWN
is never treated as free (fail-closed).

**Override (the only way to remove a lock you do not hold):**

```bash
scripts/lock.sh <env> override <deploy|data-tier> --reason "<text>" --confirm
```

Requires both `--reason` and `--confirm`; refuses if the lock is already
free; **writes a dated audit report BEFORE deleting** — if the reason text
looks secret-shaped (`password=`, `token=`, a bearer token, an AWS-style
access key, a `user:pass@` URL, …) or the report cannot be written for any
other reason, the override is **ABORTED and the lock is NOT deleted** — there
is no path that deletes a lock without a written audit trail. The report
names the previous holder, their operation, the lock's age, and the given
reason.

**`data-tier` has no automatic release by any route** — not on process exit,
not on a crash, not on Ctrl-C/SIGTERM. `lock_mark_for_auto_release` (the
auto-release registration used by `deploy`) **refuses to register
`data-tier` at all**. Only an explicit `lock_release` (after the operator
verifies the data tier is actually available again) or `override` (with the
audit trail above) ever removes it. This is deliberate: a crash between
"park started" and "verified unparked" must leave the lock held, never
silently free.

**No TTL, no auto-steal.** A stale lock is only ever surfaced by `status`
(with its age) and removed by the explicit, audited `override` — nothing
times it out automatically.

**The residual race (known, not closed by this epic):** `terraform-cd`
checks the `data-tier` lock twice — before `plan`, again before `apply` — but
holds nothing of its own during `apply` itself. A park (`power-data.sh down`)
that acquires the lock strictly AFTER `terraform-cd`'s own second check (and
before `apply` actually finishes) is not blocked. `scripts/deploy-prod.sh`'s
own re-check narrows the equivalent window for deploys to the few seconds
between its preflight and its snapshot/roll calls, but does not close it
either. Closing this fully needs `terraform-cd` itself to hold the lock
across the whole `apply` step — a workflow-file change, out of this story's
ownership; flagged to the lead rather than attempted here.

---

## 5. Roll (`scripts/roll-service.sh`) and `ssm-exec.sh` exit codes

`roll-service.sh` is the mechanism `deploy-prod.sh` calls; it can also be run
directly (e.g. from `dev-auto-promote.yml`) with `KEY=<env-key>
IMAGE_TAG=<tag> SERVICE=backend|frontend|biocompute scripts/roll-service.sh`.
For a backend roll it NEVER passes `--no-deps` — a plain `docker compose up
-d <targets>` runs the compose `migrate:` dependency first and refuses to
start the backend containers if the gate fails, leaving the previous
containers serving untouched. See §1 for the box-conversion refusal.

**`ssm-exec.sh` exit codes — the contract every caller branches on:**

| Exit | Meaning | What a caller must do |
|---|---|---|
| `0` | Success — the remote command reached a terminal `Success` state before the wait expired | proceed |
| `1` | A terminal `Failed`/`Cancelled`/`TimedOut` state reached before the wait expired — a **real, known** remote failure | treat as a definite failure |
| `2` | **INDETERMINATE** — the wait expired before any terminal state; the script cancels the command (`aws ssm cancel-command`) and prints `status: INDETERMINATE` rather than guessing | **never advance `:stable`**; do not blindly retry/restore — the remote state is unknown, not known-bad. Check the box by hand. |

**Manual checks for an INDETERMINATE (exit 2) result** — do these before
retrying anything:

```bash
scripts/ssm-exec.sh -e <env> 'docker compose -f /opt/axiome/docker-compose.yml ps'
scripts/ssm-exec.sh -e <env> 'docker compose -f /opt/axiome/docker-compose.yml logs --no-log-prefix migrate'
scripts/ssm-exec.sh -e <env> 'cat /opt/axiome/.env | grep _IMAGE_TAG='   # never do this with a real secret-bearing file — .env here carries only tags
```
Confirm which image tag is ACTUALLY running (`docker compose ps` image column)
before trusting the `_IMAGE_TAG` value recorded in `.env` — a roll writes
that value BEFORE the gate runs, so on a gate failure it can briefly name a
tag that never actually started serving.

---

## 6. Park / unpark (`power.sh`, `power-data.sh`, `power-up-all.sh`)

**Compute (daily, safe) — `power.sh <env> <up|down|status>`:**

- `down` runs the on-box Mongo backup over SSM FIRST, then independently
  **verifies** it (not just trusts the on-box script's own claim): the
  verification requires a `head-object` that shows `ContentLength > 0`,
  `LastModified` not earlier than when the backup was issued, and the
  object's `sha256` metadata matching the backup script's own reported
  checksum. Only then does it stop the instance. Any `ssm-exec.sh` non-zero
  result (including the INDETERMINATE 2) refuses the stop.
- `--skip-backup "<reason>"` overrides the backup requirement — the reason
  must be non-empty and must not look secret-shaped (same guard family as
  lock override's `--reason`); it is written to the audit report before the
  stop proceeds.
- `up` polls `/api/v1/health/ready` (through the public edge) and prints the
  last response body on a timeout.
- Env knobs: `AXIOME_HEALTH_URL`, `BACKUP_SSM_WAIT` (default 180s),
  `POWER_UP_HEALTH_TIMEOUT_SECONDS` (default 600s),
  `POWER_UP_HEALTH_POLL_INTERVAL` (default 5s).

**What holds the data-tier lock, and when it is released — `power-data.sh
<env> <down|up|status>`:**

- `down` **acquires** the `data-tier` lock before touching anything, writes
  the acquired token to `s3://<system-bucket>/power-data/park-state.env`
  immediately (before any stop/delete — if THAT write itself fails, the lock
  is released and nothing is touched), then stops RDS and — only after a
  verified config capture — snapshots and deletes the ElastiCache
  replication group, waiting for the final snapshot to be confirmed
  `available` before ever reporting success. **`down` never releases the
  lock.**
- `up` starts/recreates both tiers, waits (bounded) for BOTH to report
  `available`, and **releases the lock only then** — never from a
  trap/finally. If the wait times out, the lock stays held and the operator
  is told to investigate and re-run `up`.
- A second `down` while already parked is refused at the lock, with no AWS
  mutation at all.
- `up` with nothing parked makes no lock call at all (nothing to release).
- `up` after an `override` (lock removed out-of-band): the recorded park
  token is gone, so the release is cleanly skipped with a warning naming
  `scripts/lock.sh <env> status data-tier` — the stale `park-state.env` is
  left for the operator (not auto-cleared on this path).

**One-call turn-on (validated superset) — `power-up-all.sh <env> [--yes]`
(or `make turn-on ENV=<env> [YES=1]` from `providers/aws/`):** read-only
preflight (AWS identity, current state, and — if Redis is `absent` — that
BOTH the `redis-state.env` file and its referenced final snapshot exist and
are `available`, since that snapshot is the only copy) ALWAYS runs first and
aborts before any mutation on a missing input. The mutating run needs
`--yes` (or `POWER_CONFIRM=1`); without it, the command is a safe dry run.
Order: data tier up and verified healthy FIRST, then compute — the app must
never start against a cold DB/Redis. Keep `terraform-cd` gated for the whole
window (Redis is recreated outside Terraform); confirm `terraform plan`
shows no changes before un-gating it.

**Installing the Mongo backup timer — `install-mongo-backup-timer.sh <env>`
— this has never been run.** It is a one-time operator conversion (same
category as §1's box conversion): moves a box from cron-only Mongo backup
(no catch-up if a run is missed) to a systemd timer
(`OnCalendar=daily, Persistent=true` — the mechanism that actually satisfies
"catches up a missed run on box start"). Precondition: the box must already
be on the asset-sync channel (§1) and have pulled at least once since
`mongo-backup.timer`/`.service` were published — the script refuses with a
clear message if those files are not yet on disk, rather than silently doing
nothing. It is never executed by this story, by CI, or against any real box.

---

## 7. Local stack safety (AXI-1952)

- **Compose v2 is required** — the root `Makefile` refuses with a clear
  `$(error)` (not a silent fallback to the legacy `docker-compose` v1 binary,
  which has a known data-corrupting bug against modern image config) when no
  usable `docker compose` is found, **for any goal that actually touches
  Docker Compose** (AXI-1955 fix (a) — `make help` and every Terraform/seed/
  deploy-prod target need no Docker at all and work without it). A literal
  `DOCKER_COMPOSE=docker-compose` override (command line OR environment) is
  also rejected (AXI-1955 fix (b)) — only `DOCKER_COMPOSE="docker compose"`
  (or leaving it unset, letting `make` probe for v2 itself) is accepted.
- **Purge guard** (`wt_purge_guard` in `scripts/wt-common.sh`): `wt-down.sh
  --purge` only proceeds if every target resource name contains the
  worktree's own slug, no resource equals a known SHARED name, the slug
  itself matches `[a-z0-9][a-z0-9-]*` (no glob/regex metacharacters), and the
  Redis index is not the shared index (0 or 1). All violations are listed
  before refusing — nothing is deleted on a partial pass.
- **`wt-down.sh --purge-shared --confirm DELETE-ALL-LOCAL-DATA`** — the
  literal, case-exact token is the ONLY accepted confirmation; there is no
  interactive prompt, so a piped "yes" or a closed/empty stdin can never
  satisfy it. A verified Postgres backup is taken FIRST; a failed or empty
  backup refuses the purge (same via `make shared-down PURGE=1
  CONFIRM=DELETE-ALL-LOCAL-DATA`).
- **Backup-before-migrate:** `wt-migrate.sh apply` (used by both `wt-up.sh
  --migrate` and `make demo-up`) takes a verified `pg_dump` of the shared DB
  BEFORE running `migrate-gate apply` — a failed or empty dump refuses the
  migration outright, forward-only, no schema-push fallback of any kind. A
  second concurrent `wt-migrate.sh apply` from another worktree waits on a
  machine-local lock and then refuses rather than running concurrently.
- **`make demo-up MIGRATE=0`** skips the migration and instead prints the
  pending migrations (`wt-migrate.sh status`, read-only) before starting the
  stack anyway — useful to inspect drift without committing to a migration.

---

## 8. What the next approved `terraform apply` will change

(From the AXI-1950/1951 learnings — **described, never run** by this epic.)

- `aws_s3_object` publishing of the on-box asset bundle in both
  `compute-ec2` and `compute` (Lightsail) modules, including three new
  objects for the Mongo backup timer unit (`mongo-backup.service`,
  `.timer`, plus the script itself) — the Lightsail module gains the
  `mongo_backup_script` object it was previously missing.
- `aws_db_event_subscription.rds_auto_restart` (new, `modules/alerting`) —
  an alert on AWS's own 7-day auto-restart of a stopped RDS instance.
- The rendered `user_data` on the EC2 compute module changes (the systemd
  `ExecStart` now points at `/opt/axiome/scripts/boot.sh`, cloud-init
  bootstraps the on-box layout). **The two readings of this disagree — treat
  the stricter as true until a real plan is read:** the developer's reading
  (and the lead's, cross-checked against the AWS provider docs) is that a
  `user_data` change triggers a stop/start of the instance in place
  (`user_data_replace_on_change = false` means the instance is NOT replaced,
  but a `user_data` diff is still applied by a reboot-in-place on most
  provider versions); the reviewer's reading was no restart at apply. For
  the Lightsail (dev) module, ANY cloud-init change **destroys and recreates**
  the instance (pre-existing behaviour, unrelated to this epic). After this
  one change, on-box file updates happen entirely through `aws_s3_object` +
  `asset-sync.sh pull` — no further `user_data` changes are expected from
  future on-box file additions.
- `terraform-cd` is currently **red at `terraform fmt -check`** on
  `modules/compute/main.tf` (alignment of `NODE_ENV`/`PORT`), independent of
  this epic (confirmed red before any AXI-1944 commit) — no production plan
  or apply has run since. **No story in this epic may fix that formatting as
  a side effect** — doing so re-arms the production plan and queues an apply
  for the owner's (`fmguimaraes`) approval; that is the owner's call, not an
  incidental fix.

---

## 9. Known gaps

- The deploy/park lock race (§4) is narrowed, not closed — `terraform-cd`
  itself needs to hold the `data-tier` lock across its whole `apply` step to
  close it fully.
- `seed-environment.sh --check`'s baseline verification is structurally
  `NOT PERFORMED` in `deploy-production.yml` today (that workflow checks out
  only `axiome-infra`) — adding an `axiome-back` checkout (or
  `AXIOME_BACK_PATH`) to the workflow is an owner decision, not yet made.
  "Baseline verification: NOT PERFORMED" is therefore the routine, expected
  result in CI/automation, not a signal something is wrong.
- `install-mongo-backup-timer.sh` has never been run against a real box.
- Nothing in this runbook — box conversion, baselining, deploy, roll,
  park/unpark, locks — has been exercised against live AWS. Every behaviour
  above is proven by the shell scripts' own logic and this repo's offline,
  stubbed bats suite (`tests/run.sh`), never a real `terraform apply`, SSM
  command, or AWS mutation. Treat every exit code / refusal message above as
  "what the code says it does", not as field-verified.
- Local vs CI shellcheck version skew (§0) — a clean local run is not proof
  CI will be clean.
