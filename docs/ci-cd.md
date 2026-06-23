# CI/CD Pipeline

This document describes how a code change in a service repo (`axiome-front`,
`axiome-back`, `axiome-bio-compute`) reaches a running container in an
environment. If you are new to the project, start here.

## The chain at a glance

```
  ┌──────────────────────── service repo (e.g. axiome-front) ──────────────────────────┐
  │                                                                                    │
  │  push to main ─► .github/workflows/ci.yml                                          │
  │                     ├─► test (lint, unit, tsc)                                     │
  │                     ├─► build-push-notify (uses reusable-build.yml @ axiome-infra) │
  │                     ├─► promote-staging    (update-manifest.sh <svc> staging)      │
  │                     └─► promote-production  (update-manifest.sh <svc> production)  │
  │                          (chained via needs:, automatic on every push to main)     │
  │                                                                                    │
  └──────────────────────────────────────────┬─────────────────────────────────────────┘
                                             │
                                             │ reusable-build.yml
                                             │   1. docker build .
                                             │   2. docker push to ECR
                                             │      <acct>.dkr.ecr.<region>.amazonaws.com/
                                             │        ${REGISTRY_NAMESPACE}/<service>:<sha>
                                             │   3. POST /repos/.../dispatches
                                             │      event_type: image-published
                                             ▼
  ┌────────────────────────────── axiome-infra repo ─────────────────────────────────┐
  │                                                                                  │
  │  repository_dispatch ─► .github/workflows/dev-auto-promote.yml                   │
  │                            └─► scripts/update-manifest.sh <service> dev <tag>    │
  │                                  edits providers/${PROVIDER}/environments/dev/   │
  │                                        images.tfvars and pushes a commit         │
  │                                                                                  │
  │  push to main (paths: tf, tfvars, providers/**, scripts/** —                     │
  │                 dev/staging images.tfvars excluded) ─►                            │
  │       .github/workflows/terraform-cd.yml                                         │
  │          ├─► ci-gate            (terraform fmt + validate + plan — infra CI)      │
  │          └─► apply-production   (needs ci-gate; environment: production)          │
  │                ├─► [GATE] production Environment required reviewers (approval)    │
  │                ├─► export-deploy-credentials composite action                    │
  │                │     (validates AWS_*, NEON_API_KEY, MONGODB_ATLAS_*)            │
  │                └─► scripts/deploy.sh production                                   │
  │                      cd providers/${PROVIDER}/ ; terraform init/plan/apply       │
  │                                                                                  │
  │  PR (paths: tf, tfvars, …) ─► .github/workflows/terraform-ci.yml                 │
  │                                  fmt + validate + plan                           │
  │                                                                                  │
  └──────────────────────────────────────────────────────────────────────────────────┘
```

Promotion is **fully automatic** on every push to a service repo's `main`:

- **Auto-deploy to dev** — `dev-auto-promote.yml` rolls the new image onto
  the dev VM (SSM/SSH), independent of the staging/production path.
- **Auto-promote to staging, then production** — the service repo's
  `ci.yml` runs `promote-staging` → `promote-production` (chained with
  `needs:`), each committing `images.tfvars` to `axiome-infra`. The
  `dev → staging → production` sequence is enforced by **job ordering**, not
  by `check-promotion-gate.sh` (that script is no longer in the auto path;
  it remains for manual use).
- **Production gate (in `axiome-infra`)** — the production manifest commit
  triggers `terraform-cd.yml`, where the apply is blocked by two gates in
  order: (1) the `ci-gate` job (`terraform fmt` + `validate` + `plan`), and
  (2) the `production` GitHub Environment's **required reviewers** (manual
  approval). See [Production gate](#production-gate) below.

## Repo responsibilities

| Repo | Owns |
|---|---|
| `axiome-front`, `axiome-back`, `axiome-bio-compute` | Source code, tests, `Dockerfile`, per-service `.github/workflows/ci.yml`. |
| `axiome-infra` | Terraform code, the reusable build workflow, deployment scripts, environment manifests (`images.tfvars`), state backend bootstrap. |

Services are orthogonal — failure in one service's CI never blocks another.

## Multi-provider codepath routing

The repo holds parallel infra trees under `providers/{aws,scaleway,onprem}/`,
plus a legacy top-level Scaleway tree. CI is routed by the `PROVIDER` env
var, which the workflows source as:

```
${{ vars.PROVIDER || vars.REGISTRY_PROVIDER || 'aws' }}
```

So `vars.PROVIDER=aws` (preferred) or `vars.REGISTRY_PROVIDER=aws` makes
`scripts/deploy.sh`:

- `cd providers/aws/` before `terraform init`,
- read env config from `providers/aws/environments/<env>/`,
- read backend config from
  `providers/aws/environments/<env>/backend.hcl`.

`scripts/update-manifest.sh` follows the same convention — it writes to
`providers/${PROVIDER}/environments/<env>/images.tfvars`, so auto-promote
commits land on the codepath that `terraform-cd` actually applies.

The top-level `main.tf` (Scaleway) is reachable only by setting
`PROVIDER=scaleway`. It is currently inactive — no CI path drives it.

## ECR image naming

Reusable-build composes the image path as:

```
<registry-url>/${REGISTRY_NAMESPACE}/<service>:<short-sha>
```

For the current AWS account: `225201317100.dkr.ecr.eu-west-3.amazonaws.com/axiome/frontend:96414bd6`.

The `axiome/` namespace is a property of the ECR layout (we have repos
`axiome/frontend`, `axiome/backend`, `axiome/biocompute` — not bare
`frontend` etc.), set via `vars.REGISTRY_NAMESPACE`.

**ECR repositories do not auto-create on push.** Each repo must exist
before the first build, or the push fails with
`RepositoryNotFoundException`. Repos were created manually; see the
deferred follow-up in `docs/architecture-evolution.md` to add an
auto-create step to `reusable-build.yml`.

## State backend (AWS S3)

Terraform state lives on AWS S3 with DynamoDB locking, per-environment:

| Resource | Name |
|---|---|
| S3 bucket | `axiome-<env>-tfstate` (eu-west-3, versioned, AES256-encrypted, all public access blocked) |
| DynamoDB lock table | `axiome-<env>-tflock` (PAY_PER_REQUEST, `LockID` hash key) |

`providers/aws/environments/<env>/backend.hcl` references these by name.
Both backend (S3) and resource provider (AWS) authenticate via
`AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` env vars.

Earlier the backend lived on Scaleway Object Storage with the resource
provider on AWS — the env-var name collision (S3 backend uses AWS
conventions even when pointing at non-AWS endpoints) caused real pain.
Single-cloud state + resources avoids it entirely.

## First-time setup for a new environment

```bash
# 1. Bootstrap the state bucket + lock table (one-time per env)
cd axiome-infra
AWS_ACCESS_KEY_ID=… AWS_SECRET_ACCESS_KEY=… \
  bash scripts/bootstrap-state.sh dev    # idempotent, safe to re-run

# 2. Ensure providers/aws/environments/<env>/backend.hcl matches the
#    names the script created (axiome-<env>-tfstate / axiome-<env>-tflock).

# 3. Confirm required secrets on the axiome-infra repo (see docs/secrets.md).

# 4. Create the GitHub environment if it does not exist
#    (Settings → Environments → New environment → "dev" | "staging" | "production").

# 5. Trigger terraform-cd manually with plan_only=true to dry-run.
#    Once the plan looks right, run again with plan_only=false.
```

For a new service:

1. Create the ECR repo: `aws ecr create-repository --repository-name axiome/<service> --region eu-west-3`.
2. Add `<service>_image_tag` variable + module references in
   `providers/aws/main.tf` and the `compute` module.
3. Add the initial value to each
   `providers/aws/environments/<env>/images.tfvars` (default to `latest`).
4. Add `<service>` to `SERVICE_KEYS` in `scripts/update-manifest.sh`.
5. Create the service repo's `.github/workflows/ci.yml` modeled on
   `axiome-back`'s.

## Files inventory

### Workflows in this repo

| File | Trigger | What it does |
|---|---|---|
| `.github/workflows/reusable-build.yml` | `workflow_call` from service repos | Build docker image, push to registry, dispatch `image-published` event back. |
| `.github/workflows/dev-auto-promote.yml` | `repository_dispatch: image-published` | Update `providers/${PROVIDER}/environments/dev/images.tfvars` and push. |
| `.github/workflows/terraform-cd.yml` | Push to `main`, paths under `**.tf`, `**.tfvars`, `providers/**`, `scripts/**`, etc. (dev/staging `images.tfvars` excluded) | `ci-gate` (fmt + validate + plan), then `apply-production` (`needs: ci-gate`, `environment: production`) runs `bash scripts/deploy.sh production`. Apply on push and on normal dispatch; plan-only only when dispatched with `plan_only=true`. |
| `.github/workflows/terraform-ci.yml` | PR to `main`, same paths | `terraform fmt -check`, `validate`, and `plan` per env. The gate before merge. `terraform-cd`'s `ci-gate` mirrors it for push-triggered applies (this workflow only runs on PRs). |
| `.github/workflows/secrets-check.yml` | Push / PR | Pre-commit secret scanning. |

### Composite actions

| Path | What it does |
|---|---|
| `.github/actions/export-deploy-credentials/` | Validates and exports `AWS_*`, optionally `NEON_API_KEY`, `MONGODB_ATLAS_*` into `$GITHUB_ENV`. Single source of truth for credential plumbing across the three deploy jobs. |

### Scripts

| Script | Usage | Description |
|---|---|---|
| `scripts/bootstrap-state.sh` | `<env>` | One-time create of S3 bucket + DynamoDB lock table for an environment. Idempotent. Requires AWS creds in env. |
| `scripts/deploy.sh` | `<env> [--plan-only]` | Drives `terraform init/plan/apply` inside `providers/${PROVIDER}/`. Requires `PROVIDER` env var. |
| `scripts/update-manifest.sh` | `<service> <env> <tag>` | Updates one service tag in `providers/${PROVIDER}/environments/<env>/images.tfvars` and commits. |
| `scripts/check-promotion-gate.sh` | `<service> <env> <tag>` | Verifies the tag exists in the previous environment (dev before staging, staging before production). |

### Manifests

| File | Updated by |
|---|---|
| `providers/aws/environments/dev/images.tfvars` | `dev-auto-promote.yml` (automatic). |
| `providers/aws/environments/staging/images.tfvars` | Service repo `promote-staging` job (automatic on push to `main`). |
| `providers/aws/environments/production/images.tfvars` | Service repo `promote-production` job (automatic on push to `main`; the resulting commit triggers `terraform-cd` and its gates). |

Format:

```hcl
backend_image_tag    = "abc12345"
biocompute_image_tag = "def67890"
frontend_image_tag   = "ghi13579"
```

Each service tag is independent — they do not need to match across services.

## Promotion gate

### Sequencing (service repos)

The `dev → staging → production` order is enforced by **job ordering** in
each service repo's `ci.yml`: `promote-staging` runs after
`build-push-notify`, and `promote-production` runs after `promote-staging`
(`needs:`). Because all three jobs promote the **same** short-SHA tag from
one push, the sequence is satisfied by construction. The older
`check-promotion-gate.sh` (which compared `images.tfvars` across
environments) is no longer in the automatic path — it remains in the repo
for manual/ad-hoc promotions.

### Production gate (`terraform-cd.yml`)

The production apply is the one gated step, because production is the only
live environment and hosts stateful data. A production `images.tfvars`
commit triggers `terraform-cd.yml`, where `apply-production` is blocked by
**two gates, in order**:

1. **`ci-gate` job (infra CI, in the workflow YAML)** — `terraform fmt
   -check`, `terraform validate`, and a production `terraform plan`. If any
   fail, the apply never runs. This mirrors `terraform-ci.yml`, which only
   runs on PRs, so push-triggered applies get the same validation.
2. **`production` Environment required reviewers (manual approval, a repo
   setting — NOT in the YAML)** — `apply-production` declares
   `environment: production`; the *approval rule itself* is configured under
   **Settings → Environments → production → Required reviewers** in
   `axiome-infra`. GitHub pauses the job for an approver before its steps
   run.

   > **Important:** the YAML reference is necessary but not sufficient. If
   > Required reviewers is *not* configured on the `production` environment,
   > `apply-production` proceeds automatically once `ci-gate` passes — there
   > is no human gate. Configuring it is a one-time repo setting.

Only after both gates does `apply-production` run
`bash scripts/deploy.sh production` (real apply on push and on a normal
manual dispatch; plan-only only when dispatched with `plan_only=true`).

For the operator procedure — enabling the gate and approving a waiting
deployment (UI, mobile, and `gh` CLI) — see **Approve a production
deployment** in [`docs/runbooks.md`](runbooks.md).

`dev`/`staging` `images.tfvars` commits are excluded from the
`terraform-cd` push trigger: they do not affect the production plan
(`dev` deploys via `dev-auto-promote.yml`; `staging` is scaffold-only with
no live infra), so a staging promotion does not spuriously open a prod
approval.

## Secret access (cross-repo workflow_call)

For `secrets: inherit` to work when a service repo calls
`fmguimaraes/axiome-infra/.github/workflows/reusable-build.yml@main`:

`axiome-infra → Settings → Actions → General → Access → "Accessible from
repositories owned by the user"`.

Without this, the call fails with
`workflow is not allowed to access this resource`.

## Troubleshooting

### Build job's "Login to registry" fails or hangs

`Cannot perform an interactive login from a non TTY device` means a
secret expected by `docker login` was empty. Check the **Debug context**
step in `reusable-build.yml` for which `secrets.X` or `vars.X` came
through empty. Most common: `REGISTRY_PROVIDER` was stored as a Variable
on the calling repo but the workflow only read `secrets.X`. Both
contexts are now checked with `vars.X || secrets.X` fallback — make sure
your service repo is on the current `axiome-infra/main`.

### Push fails with `RepositoryNotFoundException`

ECR doesn't auto-create repos. Create it manually:

```bash
aws ecr create-repository --repository-name axiome/<service> --region eu-west-3
```

### Notify-infra step "green" but downstream doesn't fire

The curl call returned 401/4xx but the step didn't fail. Look at the
HTTP code printed by the step — if it's not 2xx, `GH_PAT` on the service
repo is unset, expired, or missing `Contents: write` on `axiome-infra`.

The hardened version of the step now fails red on non-2xx. If you don't
see the `HTTP <code>` line, the workflow is running an older SHA — push
a fresh commit (not "Re-run").

### terraform-cd: "No valid credential sources found" or `case ""`

`AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` empty in the
**Export provider credentials** step's env dump. Either the secrets are
missing on `axiome-infra` (not on the service repos — different store), or
the deploy job's `environment:` block can't see them.

### dev-auto-promote: `Input required and not supplied: aws-region`

`aws-actions/configure-aws-credentials` failed because `AWS_REGION` resolved
empty. `dev-auto-promote.yml` runs **natively in `axiome-infra`** and reads
*this repo's* `vars.AWS_REGION || secrets.AWS_REGION` — it does **not** inherit
the service repo's value (only `reusable-build.yml`, called with
`secrets: inherit`, does). The build/push step can therefore succeed while
dev-auto-promote fails on the same push.

Fix: set `AWS_REGION = eu-west-3` (Variable) on `axiome-infra` (see
`docs/secrets.md`). The workflow also falls back to `eu-west-3` if unset, so a
current `axiome-infra/main` won't hit this — push a fresh commit rather than
"Re-run" if you're on an older SHA. The same applies to the AWS access keys:
they must exist on `axiome-infra` itself, not just the service repos.

### terraform-cd: Neon / MongoDB Atlas 401

Provider-specific API keys missing or wrong on `axiome-infra`. See
`docs/secrets.md`. For Atlas, also check the IP allowlist in the project:
GitHub Actions runner IPs change, so `0.0.0.0/0` is the pragmatic value
for CI.

### Re-running a failed run doesn't pick up workflow fixes

When the failure is in a workflow loaded via `@main` from another repo
(typically `reusable-build.yml`), "Re-run" reuses the SHA from the
original dispatch. The fix you pushed to `axiome-infra/main` is invisible
until a fresh trigger fires. Push a commit to the service repo (empty is
fine: `git commit --allow-empty -m "ci: rerun"`) or use the Actions UI
"Run workflow" instead of "Re-run".

In-repo workflows (`dev-auto-promote.yml`, `terraform-cd.yml` themselves)
are safe to "Re-run" — they reload from `axiome-infra/main`.

## Known follow-ups

- **Automatic prod promotion is wired and gated, but does not yet roll the
  running production containers.** Production runs the EC2 compute module
  with `use_ssm_image_tags = false` (the variable default) and
  `user_data_replace_on_change = false`. So when `promote-production` writes
  a new SHA into `production/images.tfvars` and `apply-production` runs,
  Terraform updates the instance's stored `user_data` but does **not**
  recreate the host or re-run cloud-init — the live containers keep running
  their current tag (today, `:stable`). The effect is **inert, not
  destructive** (no data loss), but the new image is not deployed by the
  apply alone. Actual prod rollout still goes through advancing ECR
  `:stable` + `docker compose pull` on the box (see `docs/deployment.md`).
  To make automatic prod promotion *deploy*, migrate production onto the
  SSM auto-roll path that dev already uses (`use_ssm_image_tags = true` +
  a `roll-service.sh`-style step, or a `null_resource`/`remote-exec` pull +
  restart gated on tag change).
- **Frontend image bump replaces the entire Lightsail instance.** The
  `frontend_image_tag` is rendered into `user_data`, which is `ForceNew`
  on `aws_lightsail_instance`. Every image update currently destroys and
  recreates the VM (~60–120s downtime, backend stack also bounced). The
  right fix is a `null_resource` + `remote-exec` that SSHes in and runs
  `docker compose pull && up -d <service>` gated on tag change. Tracked
  in `docs/architecture-evolution.md`.
- **No ECR auto-create step** in `reusable-build.yml`. Adding one
  requires `ecr:CreateRepository` on the build IAM keys.
- **MongoDB Atlas IP allowlist** is currently `0.0.0.0/0` for CI.
  Tightening it requires either a static egress (NAT gateway with EIP)
  or rotating allowlist entries on each run.
