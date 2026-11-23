# production / deploy-backend

- **When (UTC):** 2026-11-23T17:42:07Z
- **Actor:** arn:aws:iam::225201317100:user/axiome-terraform
- **Inputs:**
  - tag=a8e8b5e0
  - digest=sha256:f38f5143918f3f42d2dd622c7dd62d66b17e08e44abee6bb5a42160da6071e72
  - prior_tag=a8e8b5e0

- Source image: axiome/backend:a8e8b5e0 (digest sha256:f38f5143918f3f42d2dd622c7dd62d66b17e08e44abee6bb5a42160da6071e72)
- Prior :stable digest: sha256:cacc0a8bc70d8c243957228c6fd29fd581e6b9ef0e0af0fa5b5b5b5ab4a08c25
- Box was serving BACKEND_IMAGE_TAG=a8e8b5e0 before this run.
- No pending migrations (or non-production env) — no snapshot taken.
- MIGRATION_FACTS: SERVICE=organization-service SCHEMA_VERSION=20261119120000_add_analysis_template_version_workflow APPLIED=0 PRE_COUNTS=skipped POST_COUNTS=skipped
- MIGRATION_FACTS: SERVICE=user-service SCHEMA_VERSION=20261122100000_grant_template_view_source APPLIED=0 PRE_COUNTS=skipped POST_COUNTS=skipped
- Readiness PASS (https://platform.axiomebio.com/api/v1/health/ready = 200).
- Advanced :stable to a8e8b5e0.
- Baseline verification: MISMATCH (warning only — does not roll back). See the deploy log for the expected/actual table.

**Outcome:** completed
