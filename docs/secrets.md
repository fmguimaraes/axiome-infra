# Secrets and Variables

> **AXI-1977 note:** the `MONGODB_ATLAS_PUBLIC_KEY`/`MONGODB_ATLAS_PRIVATE_KEY`
> row below is only needed if Scaleway or OVH resources are ever in a
> Terraform plan (`providers/scaleway/`, `providers/ovh/`) — grep confirms
> `mongodbatlas` is not a provider in `providers/aws/` or the root module.
> Production (AWS) uses a self-hosted MongoDB container, not Atlas; see
> [providers.md](providers.md).

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
| `AXIOME_BIO_COMPUTE_READ_TOKEN` | Secret (**`axiome-back` only**) | Fine-grained PAT, owner `fmguimaraes`, repository access **only `axiome-bio-compute`**, permission **Contents: Read-only**. Token name on GitHub: `axiome-back CI read bio-compute`. | `axiome-back`'s `ci.yml` checks out `axiome-bio-compute` for the cross-repo contract test (`Test` job, AXI-1580/AXI-1675) and the mandatory method-validation contract drift check (AXI-1990, epic AXI-1911). **If it is missing or expired, `CI — Backend` fails on every run, no backend image is built, and no production deploy can be offered.** It has an expiry date: see "Rotating a secret" below. |
| `AXIOME_DOCS_READ_TOKEN` | Secret (**`axiome-back` only**) | Fine-grained PAT, owner `fmguimaraes`, repository access **only `axiome-docs`**, permission **Contents: Read-only**. Token name on GitHub: `axiome-back CI read docs`. | `axiome-back`'s `ci.yml` (`Test` job) checks out `axiome-docs` for the docs drift test (UT-CONTRACTS-1688-001) and the `libs/` unit suites (`AXIOME_DOCS_ROOT`). **If it is missing or expired, the `Test` job fails at "Checkout axiome-docs" and no backend image is built.** It has an expiry date: see "Rotating a secret" below. |
| `SLACK_WEBHOOK_URL` | Secret (**not set as of 2026-10-26**) | Slack incoming-webhook URL | Used by `ci-failure-alert.yml` and `deploy-drift.yml`. While it is unset, a red `main` or a deploy drift alerts **nobody**. Tracked in AXI-2280 (AXI-2282). |

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
| `GUIDED_ANALYSIS_ANTHROPIC_API_KEY` | Secret | Anthropic API key (`sk-ant-…`) | Guided-analysis LLM planner (organization-service). Exported as `TF_VAR_guided_analysis_anthropic_api_key` → written to SSM `GUIDED_ANALYSIS_ANTHROPIC_API_KEY` as a **SecureString**. Optional: if unset, the parameter is not created and the LLM planner arm stays unconfigured in production (the deterministic planner remains the fallback). FR35 / AC26. |
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
6. For `AXIOME_BIO_COMPUTE_READ_TOKEN` (created 2026-10-26, **expires
   2027-10-26**; it was missing before its creation date, which kept
   backend CI red):
   - GitHub emails the account owner before a fine-grained PAT expires.
     Regenerate it **before** that date: profile picture → Settings →
     Developer settings → Personal access tokens → Fine-grained tokens →
     `axiome-back CI read bio-compute` → **Regenerate token**. Keep the
     same scope: only `axiome-bio-compute`, Contents: Read-only.
   - Paste the new value at
     `github.com/fmguimaraes/axiome-back/settings/secrets/actions` →
     `AXIOME_BIO_COMPUTE_READ_TOKEN` → **Update secret**.
   - Re-run `CI — Backend` and check that the `Test` job's
     "Checkout axiome-bio-compute" step and the "Method-validation
     contract drift" job pass.
   - Symptom of an expired or missing token: `Input required and not
     supplied: token` (checkout step) or `AXIOME_BIO_COMPUTE_READ_TOKEN
     is not configured` (drift job).
   - Symptom of a token that exists but has the wrong repository access
     (e.g. left on the default "Public repositories"): both checkout
     steps fail with `Not Found - .../repos#get-a-repository`. Edit the
     token's Repository access to include `axiome-bio-compute`; the
     token value, and so the secret, does not change.
7. For `AXIOME_DOCS_READ_TOKEN` (created 2026-10-26, 1-year expiry, so
   **expires about 2027-10-26**; check the date on the token's GitHub
   page. It was missing before its creation date, which kept backend CI
   red once the earlier steps were fixed):
   - Same regeneration path as step 6, but the token is `axiome-back CI
     read docs` and its scope is only `axiome-docs`, Contents: Read-only.
   - Update secret `AXIOME_DOCS_READ_TOKEN` on `axiome-back`.
   - Re-run `CI — Backend` and check that the `Test` job's
     "Checkout axiome-docs" step passes.
   - Symptoms are the same as step 6, on the "Checkout axiome-docs" step.

> **Not a secret, but the same failure shape:** the GitHub account's
> **Actions budget** (`github.com/settings/billing/budgets`). On
> 2026-10-26 it was set to **$0 / Usage blocked**, and every CI job
> failed in about 2 s with *"recent account payments have failed or your
> spending limit needs to be increased"*. That happened even though no
> payment had failed and the usage was covered by the free discount.
> Raising that budget fixes it.

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
