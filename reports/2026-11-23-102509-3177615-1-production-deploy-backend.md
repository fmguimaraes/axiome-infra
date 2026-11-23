# production / deploy-backend

- **When (UTC):** 2026-11-23T10:25:09Z
- **Actor:** arn:aws:iam::225201317100:user/axiome-terraform
- **Inputs:**
  - tag=a8e8b5e0
  - digest=sha256:cacc0a8bc70d8c243957228c6fd29fd581e6b9ef0e0af0fa5b5b5b5ab4a08c25
  - prior_tag=49a30cd2

- Source image: axiome/backend:a8e8b5e0 (digest sha256:cacc0a8bc70d8c243957228c6fd29fd581e6b9ef0e0af0fa5b5b5b5ab4a08c25)
- Prior :stable digest: sha256:9b26d456616f3f8b75a8e26b7d520cbfa877e841a9e642a59fc2220b0cd8c5f1
- Box was serving BACKEND_IMAGE_TAG=49a30cd2 before this run.
- Pre-deploy snapshot: axiome-production-predeploy-20261123102513
- MIGRATION_FACTS: SERVICE=organization-service SCHEMA_VERSION=20261119120000_add_analysis_template_version_workflow APPLIED=0 PRE_COUNTS=skipped POST_COUNTS=skipped
- MIGRATION_FACTS: SERVICE=user-service SCHEMA_VERSION=20261122100000_grant_template_view_source APPLIED=2 PRE_COUNTS=106 POST_COUNTS=106
- Readiness PASS (https://platform.axiomebio.com/api/v1/health/ready = 200).
- Advanced :stable to a8e8b5e0.
- Baseline verification: MISMATCH (warning only — does not roll back). See the deploy log for the expected/actual table.

**Outcome:** completed
