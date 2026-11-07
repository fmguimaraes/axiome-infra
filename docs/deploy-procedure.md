# Deploy Procedure (operator quick reference)

**How to ship a change to production, and where to click "approve".** This is the
short operational runbook. For the full pipeline design see
[ci-cd.md](ci-cd.md); for the deep deploy reference (script internals, health
paths, catch-up plan) see [deployment.md](deployment.md); for branching/lifecycle
see [gitops-lifecycle.md](gitops-lifecycle.md).

> **Only production is live.** dev/staging are scaffold-only. "Deploy" here means
> production unless stated otherwise.

---

## 1. Which path do I use?

There are **two** production deploy paths, and they ship **different kinds of
change**. Both pause for one-click human approval on the same protected
`production` GitHub environment — which is exactly why it's easy to look at the
wrong one.

| I changed… | Repo | Ships via | What it does |
|---|---|---|---|
| **App code** (backend / frontend / bio-compute) | a service repo | **`deploy-production`** workflow, or `make deploy-prod` | Advances ECR `:stable` to the new image, rolls the box over SSM (`docker compose pull` + `prisma migrate deploy` + `up -d`), health-checks, fail-closed. |
| **Infra / secrets / config** (`.tf`, `providers/**`, `scripts/**`, a workflow, an SSM param) | `axiome-infra` | **`terraform-cd`** workflow | `terraform plan` → (approval) → `terraform apply`. |

**Rule of thumb:** if what you changed lives in `axiome-infra` and is Terraform/
config, it's **`terraform-cd`**. If you changed application code and want the
running containers to move, it's **`deploy-production`**.

> A green **`promote-to-production`** CI job is **not** a deploy — it only records
> the image tag in `images.tfvars`. Production pins `:stable`, so a manifest bump
> is inert until a `deploy-production` run (or `make deploy-prod`) advances
> `:stable`. See [deployment.md](deployment.md#production-deploy-aws--authoritative--fr9ac8-fr14ac19).

---

## 2. Approving a gated production deployment ← the "approve where"

When a run reaches the production step it **pauses and waits for a reviewer**. It
does **not** apply/deploy until approved.

1. Repo **`axiome-infra`** → **Actions** tab.
2. In the **left sidebar pick the right workflow** — this is the step that trips
   people up:
   - **`terraform-cd`** for an infra/secret/config change.
   - **`deploy-production`** for an app/code deploy.
   - (`deploy-production` runs triggered by a green build show up as
     *"image-published"* via repository_dispatch.)
3. Open the **latest run** (match it by its commit message / trigger).
4. Click **`Review deployments`** (yellow "Deployment review pending" banner) →
   tick **`production`** → **Approve and deploy**.

**Before you approve, read the plan/inputs:**
- `terraform-cd`: expand **Infra CI gate → terraform plan (production)** and
  confirm the plan changes only what you expect. An unexpected destroy/replace is
  a stop sign.
- `deploy-production`: confirm the **service + tag** in the run inputs are the
  ones you meant to ship.

> If several runs are stuck `Waiting`, approve the **latest** (it supersedes older
> queued runs against the same state) and cancel the stale ones.

---

## 3. Deploying app code manually (CLI alternative)

The gated workflow runs the *same* authoritative script; you can also run it
directly from a machine with AWS creds:

```bash
cd axiome-infra
make deploy-prod ENV=production TAG=<sha>                        # backend (default)
make deploy-prod ENV=production TAG=<sha> SERVICE=frontend       # or frontend / biocompute
make deploy-prod ENV=production TAG=<sha> SERVICE=frontend DRY_RUN=1   # print the plan, change nothing
```

`<sha>` is the 8-char commit SHA of a **green `main` build** of that service.
Full behaviour (preflight, `:stable` retag, roll, health-check, record) is in
[deployment.md](deployment.md#the-real-production-deploy--one-command-axi-1349fr12-axi-1350fr14ac19)
and the header of [`scripts/deploy-prod.sh`](../scripts/deploy-prod.sh).

---

## 4. Prerequisites & gotchas

- **Production may be parked.** Compute (EC2) and data (RDS + Redis) are stopped
  when idle — finding prod **stopped is normal**. Bring it up first:
  ```bash
  cd axiome-infra/providers/aws
  make turn-on ENV=production          # dry-run preflight (read-only)
  make turn-on ENV=production YES=1    # execute
  make status  ENV=production
  ```
  Detail + safety rationale: [AWS power runbook](../providers/aws/docs/power-runbook.md).
- **Keep `terraform-cd` un-approved during a power down→up window.** Redis is
  recreated outside Terraform's view; an apply mid-window fights the restore.
- **Secrets never travel as literals to SSM** (they're logged to CloudTrail); the
  on-box roll reads everything from `/opt/axiome/.env`. See
  [connect-and-debug.md](connect-and-debug.md).
- **Deploy bio-compute and the backend together (output conformance, AXI-2448).**
  The backend checks every statistical/describe result table against the operation's
  declared output columns and, by default (`OUTPUT_CONFORMANCE_MODE=block`), FAILS a run
  whose table drifts (`errorCode OUTPUT_NONCONFORMING`). A backend rolled ahead of (or behind)
  bio-compute with a changed output schema therefore turns into a run outage for that
  operation. Per-environment relief: set `OUTPUT_CONFORMANCE_MODE=warn` in `/opt/axiome/.env`
  and restart the backend. Runs then stay SUCCEEDED, with the finding in `statusMessage` and
  a structured `output_conformance` log line.
- **First-time DB catch-up is special** — `organization_svc` has no migration
  ledger; do not run a routine deploy for it. Follow
  [AXI-1347-production-catch-up-plan.md](AXI-1347-production-catch-up-plan.md).

### Post-migration data steps

Data fixes that no migration or boot seed performs; run each once per environment, after the
migrations of the release that introduced it. Each is idempotent.

- **Workspace role grants, seed step 16 (`template:write`, AXI-2465, TPL FR43 / AC12 / AC27).**
  Adds `template:write` to the seeded Admin role record (`...0104`), bumps its version and writes
  a `role_versions` row. This brings the seeded Admin record into line with `ROLE_PERMISSIONS`
  (the role-admin catalogue, and anything that reads or copies a Role's permissions). It does not
  change who can author templates: Admin members already pass `TemplateWriteGuard` through the
  legacy role fallback (`ROLE_PERMISSIONS[admin]`). Apply
  `axiome-back/scripts/seed_workspace_roles.sql` (step 16 is the last block) against the
  user-service database through `axiome-infra/scripts/seed-environment.sh` (Step 1), or run just
  that block with `psql`. Verify with
  `SELECT name, version, permissions ? 'template:write' FROM user_svc.roles WHERE id = '00000000-0000-0000-0000-000000000104';`
  (expect `t`; a re-run neither bumps the version nor adds a row).
  Applied on the demo (`axiome-localhost`) 2026-11-07; production still owed.

- **Owner approval of the boot-seeded template versions (AXI-2464, TPL FR59 / EC27 / AC27, owner
  ruling 5).** The boot seed publishes the system Analysis Template versions (T1 / T3 / T4 / T5
  `0.3`, and each version epic AXI-2455 seeds) without the author ≠ approver gate. This script
  records the owner's approval afterwards: one `content_approval_records` row and one
  `version_published` audit row per version, by the owner. Run it after the backend of the
  release has booted, since the boot seed must have written the versions first.
  **Decide the approver first; never re-run with a different email.** There is no default: the
  owner names the approver, a person with an ACTIVE platform `ADMIN` account, before the run, and
  the script refuses to run without `owner_email`. Both tables are append-only, so the first
  approver recorded for a version is permanent; a later run with another email writes nothing for
  that version and prints the approver already on record.
  ```bash
  psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -v owner_email='<owner email>' \
    -f axiome-back/scripts/approve_seeded_template_versions.sql
  ```
  It prints one line per version: the approver on record, then `written` or `already`. A re-run
  writes nothing. It aborts and writes nothing if a version is missing, invalidated or its content
  hash differs from the approved one, or if the owner is not a platform admin or is one of the
  version's authors. Verify with
  `SELECT v.template_version, t.template_id, r.approver_id FROM organization_svc.content_approval_records r JOIN organization_svc.analysis_template_versions v ON v.id = r.content_id JOIN organization_svc.analysis_templates t ON t.id = v.analysis_template_id WHERE t.scope = 'system' AND v.created_by = 'system';`
  (one row per seeded version, the owner's id). Applied on the demo (`axiome-localhost`,
  `admin@axiome.local`) 2026-11-07; production still owed.

---

## 5. Rollback & health

- **App rollback:** `:stable` is only advanced **after** the readiness check
  passes, so there is no `:stable`-level rollback to perform. A deploy that
  **fails** readiness restores itself automatically mid-run — re-rolls the box
  to the **prior tag** (`:stable` is left untouched, since it was never
  advanced) — but never reverts the schema (forward-only migration gate; see
  [migration-authoring-guide.md](migration-authoring-guide.md)). To roll back
  **manually** later (e.g. a deploy that passed health checks but regressed
  after `:stable` already advanced), re-run the deploy with the previous
  known-good `<sha>` (same `SERVICE`).
- **Health paths** (prod, polled ~5 min): backend `GET /api/v1/health/ready`
  (the real readiness check, not the always-200 liveness probe), bio-compute
  `GET /api/v1/version`, frontend `GET /` — see
  [deployment.md](deployment.md#health-checks).
- **Verify a running deploy** with the on-box helpers:
  `scripts/platform-debug.sh health` / `status` — see
  [connect-and-debug.md](connect-and-debug.md) and [troubleshooting.md](troubleshooting.md).

---

## 6. Dev / local (for reference)

- **Local:** `make local-up` / `make local-down` (see the [README](../README.md)).
- **dev/staging:** scaffold-only; there is no live dev/staging deploy to approve.
