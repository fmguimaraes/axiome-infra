# Incident — Production feedback (and all transactional) emails silently not sent

- **Date:** 2026-08-26
- **Environment:** production (`platform.axiomebio.com`, EC2 `i-0fce8b81eab806118`)
- **Severity:** low user impact, high silent-failure risk — no data lost, but every
  outbound email (feedback notifications, @mentions, password reset, welcome, export,
  sponsor-publish) was being dropped without any error surfaced to users.
- **Status:** remediated live; permanent IaC fix landed (this commit). One gated prod
  `terraform apply` still pending to bring the SSM params under Terraform state.

## Symptom

A user submitted a message through the in-app **feedback button** and the expected
admin-notification email never arrived. The UI reported success (no error toast).

## What actually happened

The feedback pipeline worked end-to-end **except the email send**:

1. `POST /api/v1/feedback` → gateway → RabbitMQ (`feedback.create`) → user-service.
2. user-service **persisted the row** to the `feedback` table (durable; happens first).
   Two rows were written during testing and are intact:
   - `5726ca54-25c7-44f9-b4fb-4a7d74d625ea` (QUESTION, 04:39:20 UTC)
   - `919dd6de-63d3-433e-89a8-03c9b9b49910` (IMPROVEMENT, 04:48:21 UTC)
3. `FeedbackService.notifyAdmins()` is **best-effort** (wrapped in try/catch; a failure
   is logged, never fails the request) — which is why the submit still returned success.
4. `EmailService` logged **`Mailjet NOT configured — MAILJET_API_KEY=missing,
   MAILJET_SECRET_KEY=missing`** at boot and took its log-only branch:
   `[DEV] Feedback (...) — would email: macphillis@gmail.com` — sending nothing.

## Root cause

Production had **no Mailjet credentials** in SSM, so `EmailService` never initialised
the Mailjet client.

The Terraform resources for the two secret params are guarded on a non-empty variable:

```hcl
# providers/aws/modules/secrets/main.tf
resource "aws_ssm_parameter" "mailjet_api_key" {
  count = var.mailjet_api_key != "" ? 1 : 0   # <-- 0 when the var is empty
  ...
}
```

The variables (`providers/aws/variables.tf`) are documented as *"Sourced from the
`MAILJET_API_KEY` GitHub secret via `TF_VAR_mailjet_api_key`."* The GitHub secrets
**did exist** (set 2026-06-23) — but **`terraform-cd.yml` never injected them** as
`TF_VAR_*`. So `var.mailjet_api_key` stayed at its `""` default, `count` was `0`, and
the params were never created. The wiring was documented but dead.

Compounding it: the live box's `/opt/axiome/.env` had **zero** `MAILJET_*` lines at all
(the instance predated even the always-created `MAILJET_FROM_EMAIL`/`_NAME` params), so
the sender was also defaulting to the unverified `noreply@axiome.app`.

## Immediate remediation (live, same day)

1. Created `/production/axiome-production/MAILJET_API_KEY` and `…/MAILJET_SECRET_KEY`
   (SecureString) from the validated values.
2. Appended all four `MAILJET_*` keys to `/opt/axiome/.env` (values fetched from SSM
   **on the box** — never through Run Command / CloudTrail), then recreated
   `axiome-user-service`. Boot log flipped to **`[EmailService] Mailjet configured`**.
3. Validated against Mailjet's API: keys authenticate (HTTP 200) and the sender
   `contact@axiomebio.com` is **Active**.

## Permanent fix (this change)

- **`terraform-cd.yml`** now exports `TF_VAR_mailjet_api_key` / `TF_VAR_mailjet_secret_key`
  from the GitHub secrets on **both** the plan (`ci-gate`) and apply (`apply-production`)
  steps, so Terraform actually receives them and the SSM params are created/managed.
- Refreshed the `MAILJET_API_KEY` / `MAILJET_SECRET_KEY` GitHub secrets to the validated
  values (their old values had never been exercised by an apply).
- Deleted the two **manually-created** SSM params so the next gated prod apply creates
  them **in Terraform state** (adopting IaC ownership) rather than failing with
  `ParameterAlreadyExists`. The running box is unaffected — the values remain baked into
  `/opt/axiome/.env`.

## Follow-up / residual risk

- A gated production `terraform apply` (manual approval on the `production` environment)
  must run to (re)create the two params under Terraform state. Its plan should show
  **only** the two `aws_ssm_parameter.mailjet_*[0]` creations.
- Until that apply is approved, prod runs correctly on the baked-in `.env`, but SSM lacks
  the two params — a **VM re-render (cloud-init) before the apply would lose them**. VM
  re-render only happens on a `user_data` change / instance replacement, not on the normal
  `:stable` image-pull deploy, so the window is low-risk.
- The two feedback rows already captured had their notification emails dropped; there is
  **no resend path** (`notifyAdmins` fires once, best-effort).

## Hardening ideas (not done here)

- Add a startup/health signal when `EmailService` is in log-only mode, so a
  misconfigured email subsystem is visible instead of silent.
- Consider surfacing a soft warning to the caller (or a metric) when `notifyAdmins`
  swallows a send failure.
