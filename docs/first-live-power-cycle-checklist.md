# First live power cycle — step by step

What has to happen, in order, before production power-down and power-up work
end to end with the AXI-1944 safeguards (verified backup before stop, migration
gate on boot, readiness check on start, locks).

**Nothing below has ever been run against AWS.** Every command comes from
reading the scripts on `main`; treat each first run as a test, and stop at the
first result you did not expect. The detailed reference is
[`platform-lifecycle-operations.md`](platform-lifecycle-operations.md)
(section numbers below point there).

Tick each box as you go. Steps marked **DECISION** are yours to make; steps
marked **MUTATES PROD** change the live platform.

---

## Why it does not work today

| Operation | What happens on the current box | Fixed by |
|---|---|---|
| `power.sh production down` | Runs `/opt/axiome/scripts/mongo-backup.sh` on the box first. Not installed yet, so the backup fails and compute is **not** stopped. | Phase 3 |
| `power.sh production up` | Starts the instance, then polls `/api/v1/health/ready` for 10 minutes. The deployed backend may predate that endpoint's new behaviour, so the script can exit non-zero with the platform actually up. | Phase 2 |
| Boot after power-up | `axiome.service` runs a bare `docker compose up -d`: no asset sync, no `.env` refresh, no migration gate. | Phase 3 |
| Backend deploy / roll | Refuses: the box's compose file has no `migrate` service. | Phase 3 |

---

## Phase 0 — Your machine (15 min, read-only)

- [ ] `aws --version` is **2.22.3 or later** (2.17.34 is the hard minimum for lock acquire).
- [ ] `date --version` prints GNU coreutils (on macOS: `brew install coreutils` and put `gdate` first as `date`).
- [ ] `jq --version` works. `make --version` is 4.2 or later.
- [ ] `aws sts get-caller-identity` shows the Axiome account.
- [ ] Fresh checkout of `axiome-infra` `main`.
- [ ] See what is really there (all read-only):

  ```bash
  cd providers/aws
  make status ENV=production                      # EC2 / RDS / Redis state
  ../../scripts/lock.sh production status         # all four locks should be FREE
  ../../scripts/ssm-exec.sh -e production 'cat /etc/systemd/system/axiome.service; ls -la /opt/axiome /opt/axiome/scripts; docker compose -f /opt/axiome/docker-compose.yml ps'
  ```

  Write down: the instance state, the current `ExecStart=` line, whether
  `/opt/axiome/scripts/` has `boot.sh` / `asset-sync.sh` / `mongo-backup.sh`,
  and the backend image tag in use.

- [ ] **Confirm production is the EC2 stack.** `environments/production/terraform.tfvars`
  says `use_ec2_compute = true`, `use_legacy_stack = false` (EC2 + RDS +
  ElastiCache, no Lightsail). If `make status` cannot find an EC2 instance
  named `axiome-production-ec2`, stop: the power scripts only handle EC2.

If production is currently parked, bring it up with the existing path
(`make turn-on ENV=production`, then `YES=1`) before Phase 3 — the conversion
needs a running box.

---

## Phase 1 — Clear the queue (5 min)

- [ ] **DECISION** — `deploy-production` run **38084678567** (commit `e2a072c`) is
  waiting for approval in `axiome-infra` Actions. It was triggered before the
  deploy workflow was changed. Recommended: **cancel it**.
- [ ] Check no other `deploy-production`, `terraform-cd` or `dev-auto-promote`
  run is in progress or waiting.

---

## Phase 2 — A backend image that has the gate and the health endpoints

Power-up's readiness check and the on-box migration gate both need a backend
image built from current `axiome-back` `main`. A backend image is only built
and promoted when `CI — Backend` is fully green, and it is red today.

- [ ] Check the current state: `gh run list -R fmguimaraes/axiome-back -w "CI — Backend" -L 5`.
- [ ] Fix the `test` job. On 2026-10-11 it failed on `user-service`
  `admin-bootstrap.service.spec.ts` (5 s Jest timeout). Find out whether it is
  a flaky test or a real regression before anything else.
- [ ] **DECISION** — merge branch `AXI-1976-livedb-harness` (`8b1f6a18`, one
  change to `.github/workflows/ci.yml`). It fixes the `livedb-constraints`
  job. Know what follows: once `test`, `migrate-from-scratch` and
  `livedb-constraints` are all green, the pipeline **builds, pushes and
  promotes the backend image**, which opens a `deploy-production` approval.
- [ ] Let the image build, but **do not approve the production deploy yet** —
  it will refuse until Phase 3 is done.
- [ ] Note the new 8-hex image tag.

---

## Phase 3 — One-time box conversion (§1) — MUTATES PROD

Goal: the box gets the new compose file (with the `migrate` service), the boot
wrapper, and the backup script, and `axiome.service` starts through `boot.sh`.

### 3a. Publish the on-box bundle to S3

The bundle normally reaches `s3://axiome-production-system/onbox/` through
`terraform apply`, which is blocked (see Phase 6). Publish it directly instead:

- [ ] Check what is there now: `aws s3 ls s3://axiome-production-system/onbox/ --recursive`
- [ ] Publish from the repo root:

  ```bash
  scripts/asset-sync.sh publish "$(pwd)" s3://axiome-production-system/onbox
  aws s3 ls s3://axiome-production-system/onbox/ --recursive   # 7 files + manifest.sha256
  ```

  Terraform will later take ownership of the same keys with the same content.

### 3b. Check the new compose file fits this box before installing it

- [ ] Compare the box's current compose file with `providers/aws/onbox/docker-compose.yml`:

  ```bash
  scripts/ssm-exec.sh -e production 'cat /opt/axiome/docker-compose.yml' > /tmp/box-compose.yml
  diff /tmp/box-compose.yml providers/aws/onbox/docker-compose.yml
  ```

  Expect: the new `migrate` service, healthchecks, `depends_on` on `migrate`.
  Anything else (a service, volume or variable that exists only on the box)
  must be understood first — the pull replaces the file.
- [ ] Confirm `/opt/axiome/.env` has `ORGANIZATION_DATABASE_URL` and
  `USER_DATABASE_URL` (names only, never print values):
  `scripts/ssm-exec.sh -e production "cut -d= -f1 /opt/axiome/.env | sort"`

### 3c. Pull the bundle onto the box

- [ ] Bootstrap `asset-sync.sh` (it is part of the bundle, so the first copy is fetched by hand), then pull:

  ```bash
  scripts/ssm-exec.sh -e production 'mkdir -p /opt/axiome/scripts && aws s3 cp s3://axiome-production-system/onbox/scripts/asset-sync.sh /opt/axiome/scripts/asset-sync.sh && chmod 700 /opt/axiome/scripts/asset-sync.sh && /opt/axiome/scripts/asset-sync.sh pull s3://axiome-production-system/onbox /opt/axiome; echo "pull exit=$?"'
  ```

  Exit 0 = installed. Any other code leaves the box as it was (§1 has the table).
  The previous compose file is kept as `docker-compose.yml.prev`.
  If the `aws s3 cp` is denied, the instance role cannot read the `onbox/`
  prefix — that needs the Terraform apply of Phase 6 first.

### 3d. Point the systemd unit at the boot wrapper

`boot.sh` **exits immediately without `ONBOX_S3_PREFIX`**, so the unit needs
the environment lines as well as the new `ExecStart` (the runbook's older
three-line version of this step was incomplete).

- [ ] Get the SSM parameter prefix: `cd providers/aws && terraform output` (or
  read it from the existing `/opt/axiome` bootstrap / Parameter Store path).
- [ ] Edit `/etc/systemd/system/axiome.service` on the box so `[Service]` contains:

  ```ini
  WorkingDirectory=/opt/axiome
  Environment=AXIOME_DIR=/opt/axiome
  Environment=ONBOX_S3_PREFIX=s3://axiome-production-system/onbox
  Environment=SSM_PARAMETER_PREFIX=<the prefix>
  ExecStart=/opt/axiome/scripts/boot.sh
  TimeoutStartSec=300
  ```

  Keep a copy of the old unit first (`cp axiome.service axiome.service.pre-AXI-1944`).
- [ ] `systemctl daemon-reload` (do **not** restart the service yet).

### 3e. Baseline any service without a migration ledger (§2)

Do this **before** the first start through the gate, or the gate will refuse
and the backend will not come up.

- [ ] Read-only status:

  ```bash
  scripts/ssm-exec.sh -e production 'cd /opt/axiome && docker compose run --rm -T migrate migrate-gate status'
  ```

  This needs the Phase 2 image on the box (`BACKEND_IMAGE_TAG` in `.env`); an
  older image has no `migrate-gate` command.
- [ ] If — and only if — the output names a service with
  `tables exist with no migration ledger`, baseline that service
  (user-service is the expected one; organization-service took 5–6 minutes
  in a test):

  ```bash
  scripts/ssm-exec.sh -e production -t 1800 'cd /opt/axiome && docker compose run --rm -T migrate migrate-gate baseline <service>'
  ```

  A status failure for any other reason (database unreachable, URL not set)
  is **not** a reason to baseline. Read §2 first.
- [ ] Re-run `migrate-gate status`; it should exit 0.

**Rollback for Phase 3:** restore `docker-compose.yml.prev` and the saved unit
file, `systemctl daemon-reload`. Nothing has been restarted up to this point.

---

## Phase 4 — First deploy through the gate — MUTATES PROD

- [ ] `scripts/lock.sh production status` — all free.
- [ ] Approve the pending `deploy-production` run for the Phase 2 image (or
  re-run it). Watch for: lock acquired, pre-flight passes, RDS snapshot,
  roll, `migrate` one-shot exits 0, new containers healthy, `:stable` advanced.
- [ ] If it refuses, the message names the cause and the remedy; do not
  override a lock unless `lock.sh status` shows it is stale.
- [ ] Verify: `curl -s https://platform.axiomebio.com/api/v1/health/ready` returns 200.

---

## Phase 5 — The first supervised power cycle — MUTATES PROD

Pick a quiet window. Keep `terraform-cd` gated for the whole time.

### 5a. Compute only (safe, repeatable)

- [ ] Down:

  ```bash
  cd providers/aws
  make power-down ENV=production
  ```

  Expect, in order: `compute` lock acquired → Mongo backup run on the box →
  backup verified in S3 (size, timestamp, checksum) → instance stopped → lock
  released. If the backup cannot be verified the instance is **not** stopped.
  Do not reach for `--skip-backup` on the first run; find out why.
- [ ] `../../scripts/lock.sh production status` — all free.
- [ ] Up:

  ```bash
  make power-up ENV=production
  ```

  Expect: instance running → `boot.sh` (asset sync, `.env` refresh, migration
  gate, containers) → readiness poll returns 200 within 10 minutes → exit 0.
- [ ] On the box, confirm the boot went through the wrapper:
  `scripts/ssm-exec.sh -e production 'systemctl status axiome.service --no-pager; docker compose -f /opt/axiome/docker-compose.yml ps -a'`
  (`axiome-migrate` should show `Exited (0)`).
- [ ] Log in to the platform and open one study.

### 5b. Full park, only once 5a is clean

Redis is snapshotted and **deleted** by a data-tier park; the snapshot is the
only copy.

- [ ] `make down ENV=production` — compute down (as 5a), then RDS stopped and
  Redis snapshotted and deleted. The `data-tier` lock stays held while parked;
  that is intended.
- [ ] `make turn-on ENV=production` — read-only preflight; must report the
  Redis snapshot present.
- [ ] `make turn-on ENV=production YES=1` — data tier up and healthy first,
  then compute. The `data-tier` lock is released when both tiers are available.
- [ ] `make status ENV=production`, `lock.sh production status`, log in.

### 5c. Backup timer

- [ ] `providers/aws/scripts/install-mongo-backup-timer.sh production`
- [ ] `scripts/ssm-exec.sh -e production 'systemctl list-timers mongo-backup.timer --no-pager'`

---

## Phase 6 — Re-arm Terraform — DECISION

`terraform-cd` fails on purpose at `terraform fmt -check`
(`providers/aws/modules/compute/main.tf`). Fixing the formatting makes the
pipeline plan against production and queue an apply for approval.

- [ ] Run `terraform fmt` on that file, commit, and **read the plan before
  approving**. Expected in the plan: the `onbox/` S3 objects (already
  published by hand in 3a — content should match), the RDS auto-restart event
  subscription, and a `user_data` change on the EC2 instance.
- [ ] The EC2 module sets `user_data_replace_on_change = false`, so the
  instance should **not** be replaced. Expect the apply to **stop and start
  the instance in place** to set the new `user_data` (a short outage; the
  box then boots through `boot.sh`), so schedule it like a power cycle. If
  the plan shows the instance being destroyed or replaced, do not approve.
- [ ] The apply takes the `apply` lock; it refuses while a deploy, a park or a
  compute power operation holds its lock.

---

## Afterwards

- [ ] Record what happened against the manual scenarios in
  `axiome-docs/manual-e2e/AXI-1944-Platform-Lifecycle-And-Migration-Hardening.md`.
- [ ] Note every place where a script behaved differently from this file — that
  is a defect in the script or in this document, and worth a story.
- [ ] Move epic AXI-1944 to Done in Jira when satisfied.

## If something goes wrong

- A lock is left held after a killed run: `scripts/lock.sh production status <name>`,
  then `override <name> --reason "<text>" --confirm` — only when the holder is
  confirmed dead.
- Power-up starts the instance but the readiness check times out: the script
  prints the last response body. Check `docker compose ps -a` and
  `docker compose logs migrate` on the box; a gate refusal keeps the backend
  containers from starting and says why.
- Exit codes for every script: §10.
