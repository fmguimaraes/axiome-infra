# Secrets and Variables

Where every credential lives, who needs it, and why.

## Principles

- **No plaintext secrets in the repo.** `secrets-check.yml` scans every
  push and PR.
- **Secrets are scoped to the smallest workflow that needs them.** Each
  service repo holds only the credentials its own CI requires;
  long-running infra credentials live on `axiome-infra`.
- **Variables vs Secrets.** Non-sensitive values (region, provider name,
  namespace) are stored as GitHub Repository **Variables** so they're
  visible in the UI. Credentials use **Secrets**. Workflows read
  variables with `vars.X || secrets.X` fallback so either location works
  without code changes.

## Where each value lives

### `axiome-front`, `axiome-back`, `axiome-bio-compute` (service repos)

The build/push pipeline. Each service repo needs its own copy unless
you put them at the organization level.

| Name | Kind | Value / source | Why |
|---|---|---|---|
| `REGISTRY_PROVIDER` | Variable | `aws` | Selects the registry branch in `reusable-build.yml`. |
| `REGISTRY_NAMESPACE` | Variable | `axiome` | Prefix inserted between registry URL and service name (ECR repos are named `axiome/<service>`). |
| `AWS_REGION` | Variable | `eu-west-3` | ECR region. |
| `AWS_ACCOUNT_ID` | Secret | 12-digit AWS account number | Used to compose ECR URL `<acct>.dkr.ecr.<region>.amazonaws.com`. |
| `AWS_ACCESS_KEY_ID` | Secret | IAM key with ECR push perms | Login to ECR. |
| `AWS_SECRET_ACCESS_KEY` | Secret | Paired with above | Login to ECR. |
| `GH_PAT` | Secret | PAT with `Contents: write` on `axiome-infra` | Used by `reusable-build.yml`'s `Notify Infra` step to POST `repository_dispatch`. Also used by the `promote-staging` / `promote-production` jobs to check out `axiome-infra` and run `update-manifest.sh`. |

IAM policy for the service-repo AWS key needs at minimum:
- `ecr:GetAuthorizationToken`
- `ecr:BatchCheckLayerAvailability`, `ecr:InitiateLayerUpload`, `ecr:UploadLayerPart`, `ecr:CompleteLayerUpload`, `ecr:PutImage`

### `axiome-infra` (deploy + terraform)

The infra repo needs broader AWS perms (it manages all the resources)
plus credentials for the third-party providers (Neon, MongoDB Atlas).

| Name | Kind | Value / source | Why |
|---|---|---|---|
| `PROVIDER` (or `REGISTRY_PROVIDER`) | Variable | `aws` | Selects the codepath under `providers/${PROVIDER}/` for `deploy.sh` and `update-manifest.sh`. |
| `AWS_REGION` | Variable | `eu-west-3` | Needed by `dev-auto-promote.yml`'s `aws-actions/configure-aws-credentials` (SSM put-parameter) and the `roll-service` SSH step. Unlike the build (which inherits the service repo's value via `secrets: inherit`), `dev-auto-promote` runs natively in this repo and reads *this repo's* `AWS_REGION`. The workflow falls back to `eu-west-3` if unset, but set it explicitly to avoid surprises. |
| `AWS_ACCESS_KEY_ID` | Secret | IAM key with broad permissions | Used by both the S3 state backend and the AWS resource provider. |
| `AWS_SECRET_ACCESS_KEY` | Secret | Paired with above | Same. |
| `NEON_API_KEY` | Secret | Neon API key, project-scoped | `kislerdm/neon` provider. Required only if Neon resources are in plan. |
| `MONGODB_ATLAS_PUBLIC_KEY` | Secret | Atlas API key (public part) | `mongodb/mongodbatlas` provider. Required as a pair. |
| `MONGODB_ATLAS_PRIVATE_KEY` | Secret | Atlas API key (private part) | Paired with above. |
| `MAILJET_API_KEY` | Secret | Mailjet API key | Transactional email (user-service `EmailService`). Exported as `TF_VAR_mailjet_api_key` → written to SSM `MAILJET_API_KEY`. Optional: if unset, email sending is disabled and the service logs links instead. Required as a pair with the secret key. |
| `MAILJET_SECRET_KEY` | Secret | Mailjet secret key | Paired with `MAILJET_API_KEY`; exported as `TF_VAR_mailjet_secret_key` → SSM `MAILJET_SECRET_KEY`. |
| `GH_PAT` | Secret | PAT with `Contents: write` on `axiome-infra` | Used by `dev-auto-promote.yml`'s `actions/checkout@v4` so the resulting commit can trigger `terraform-cd.yml` (a checkout with `GITHUB_TOKEN` would not). |

IAM policy for the infra-repo AWS key needs at minimum, beyond the
service-repo perms above:

- `s3:*` on `arn:aws:s3:::axiome-<env>-tfstate*`
- `dynamodb:GetItem`, `PutItem`, `DeleteItem` on `arn:aws:dynamodb:eu-west-3:*:table/axiome-<env>-tflock`
- `ec2:*`, `lightsail:*`, `ssm:*`, `iam:*` (or scoped equivalents) for the
  resources terraform manages — see `providers/aws/modules/**`.

For `dev` only, this is fine with a single broad-permission IAM user.
For production isolation, create separate IAM users per environment and
scope by ARN.

## GitHub environment scoping

`terraform-cd.yml`'s `apply-production` job sets `environment: production`,
which is also where the **Required reviewers** approval gate is configured
(see `ci-cd.md` → Production gate). The corresponding GitHub Environment must
exist (`Settings → Environments → New environment`), and you may scope
secrets/variables to it instead of the repository level if different
environments use different credentials.

Lookup order:

1. Secrets/variables scoped to the running job's `environment:`.
2. Otherwise: repository-level secrets/variables.
3. Otherwise: organization-level.

Repo-level is fine when all environments share an AWS account.
Per-environment scoping is the path when staging/production live in
different AWS accounts.

## Rotating a secret

1. Generate the new value at the source (AWS IAM console, Neon console,
   Atlas console, etc.).
2. Update on every repo where it's stored. Service-repo creds and
   infra-repo creds are *separate* — rotating one does not rotate the
   other.
3. For the AWS key, the old one keeps working until you explicitly
   delete it; safe to update in CI first, verify a build, then
   deactivate the old key.
4. For `GH_PAT`, regenerate with the same scopes and paste into every
   repo that uses it (both service repos for the `Notify Infra` /
   `promote` steps, and `axiome-infra` for `dev-auto-promote`).
5. Document the rotation date in the team log; CI keys deserve an
   expiry rhythm.

### Rotating `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` (flagged, FR10/AXI-983)

Rotate-then-cutover, never delete-then-create — the old key stays valid until
you explicitly deactivate it, so there is no window where CI/CD or the runtime
IAM user (`aws_iam_user.runtime` in `modules/compute-ec2`) has no working
credential:

1. Create a **second** access key for the same IAM user/user (`aws iam
   create-access-key`) — AWS allows two active keys per user.
2. Paste the new key pair into every GitHub repo/environment secret listed in
   the table above (service repos + `axiome-infra`).
3. Trigger one build/deploy per repo and confirm it succeeds with the new key.
4. Only then, deactivate (not delete) the old key: `aws iam
   update-access-key --status Inactive`. Watch for a day, then delete it.
5. Record the rotation date + reason below.

### Rotating `JWT_SECRET` (flagged, FR10/AXI-983)

`JWT_SECRET` (Terraform `random_password.jwt_secret` in
`providers/aws/modules/secrets/main.tf`, written to SSM
`/{env}/{naming_prefix}/JWT_SECRET`) signs every session token for
`user-service`, `gateway`, and `organization-service`. **Rotating it
invalidates every currently-issued token — every logged-in user is signed
out.** This is a real, user-visible production event, not a silent rotation:

1. Schedule a maintenance window / announce the forced logout.
2. `terraform taint random_password.jwt_secret` (or `terraform apply
   -replace=module.secrets.random_password.jwt_secret`) against the target
   environment, then `terraform apply` — this regenerates the value and
   updates the SSM `SecureString` in place.
3. Recreate every service that reads `JWT_SECRET` (`user-service`, `gateway`,
   `organization-service`) so they pick up the new value from `.env` on next
   boot — a rolling recreate, not a scale-to-zero, to avoid a full outage.
4. Confirm login works post-rotation (`scripts/platform-debug.sh health`, then
   a real login); expect every previously-issued token to now 401.
5. Record the rotation date + reason below.

### Rotating the Jira and Supabase tokens (flagged, FR10/AXI-983)

Neither credential lives in this repo's Terraform or CI config — they are
held outside `axiome-infra`/`axiome-back` (issue-tracker integration token,
and the credential for the legacy Supabase project behind
`axiome-back/supabase/` — see `supabase/seed_admin_user.sql`, a pre-migration
artifact kept for reference, not part of the live deploy). Rotate at the
source (Jira API-token admin page; Supabase project → Settings → API) and
update wherever each is consumed (CI secret store / password manager); there
is nothing in this repo to change. Record the rotation date + reason below —
this repo's log is the one auditable place both rotations get documented even
though the values live elsewhere.

### Restoring the `secrets` repository read-guard (FR10/AXI-983)

The dossier's gap notes "the `secrets` read-guard is lifted" — i.e. read
access to the org's separate credentials-vault repository is currently wider
than intended. That repository is **not** one of this workspace's submodules
and isn't checked out here, so it can't be inspected or fixed from this
codebase. Restoring it is a GitHub org/repo-admin action (collaborator/team
read access, or branch protection) taken directly in that repository's
Settings — an infra owner with org-admin rights needs to review its current
collaborator list against the intended access list and tighten it back down.
Record the date + who performed it below once done.

### Rotation log

| Date | Credential | Performed by | Notes |
|---|---|---|---|
| _(add an entry each time one of the above is rotated)_ | | | |

## Verifying a secret before re-running CI

Quick local probe for a freshly-pasted PAT:

```bash
TOKEN='<paste new pat>'
curl -sS -o /tmp/dispatch.body -w 'HTTP %{http_code}\n' \
  -X POST \
  -H "Accept: application/vnd.github+json" \
  -H "Authorization: Bearer $TOKEN" \
  https://api.github.com/repos/fmguimaraes/axiome-infra/dispatches \
  -d '{"event_type":"image-published","client_payload":{"service":"frontend","image_tag":"manual-test","repo":"fmguimaraes/axiome-front","sha":"test"}}'
cat /tmp/dispatch.body
```

Expected: `HTTP 204` and empty body. 401 = bad token; 404 = wrong repo
or token can't see it; 403 = token under-scoped.

For AWS keys, `aws sts get-caller-identity` returns the account/user
ARN of whoever's authenticated — useful to confirm the right key is
loaded.

## Security controls

- `secrets-check.yml` workflow runs pre-commit secret scanning on every
  push and PR.
- Terraform state contains sensitive values (DB connection strings,
  provider keys). The state bucket has versioning + AES256 encryption
  + all public access blocked. Access is gated on the IAM key
  configured on `axiome-infra`.
- The `export-deploy-credentials` composite action passes secrets via
  `env:` rather than inline `${{ secrets.X }}` expansion in script
  bodies — prevents accidental leakage if a script is logged verbatim.
- GitHub Actions automatically masks secret values in logs as `***`.
  Don't rely on this — never `echo` a secret to stdout regardless.
