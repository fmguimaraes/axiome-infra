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
- **First-time DB catch-up is special** — `organization_svc` has no migration
  ledger; do not run a routine deploy for it. Follow
  [AXI-1347-production-catch-up-plan.md](AXI-1347-production-catch-up-plan.md).

---

## 5. Rollback & health

- **App rollback:** the deploy health-check **auto-rolls `:stable` back** to the
  prior image on failure. To roll back later, re-run the deploy with the previous
  known-good `<sha>` (same `SERVICE`).
- **Health paths** (prod, polled ~5 min): backend `GET /api/v1/health`, bio-compute
  `GET /api/v1/version`, frontend `GET /` — see
  [deployment.md](deployment.md#health-checks).
- **Verify a running deploy** with the on-box helpers:
  `scripts/platform-debug.sh health` / `status` — see
  [connect-and-debug.md](connect-and-debug.md) and [troubleshooting.md](troubleshooting.md).

---

## 6. Dev / local (for reference)

- **Local:** `make local-up` / `make local-down` (see the [README](../README.md)).
- **dev/staging:** scaffold-only; there is no live dev/staging deploy to approve.
