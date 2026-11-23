# production / deploy-backend

- **When (UTC):** 2026-11-20T06:18:37Z
- **Actor:** arn:aws:iam::225201317100:user/axiome-terraform
- **Inputs:**
  - tag=49a30cd2
  - digest=sha256:9b26d456616f3f8b75a8e26b7d520cbfa877e841a9e642a59fc2220b0cd8c5f1
  - prior_tag=0af38bd1

- Source image: axiome/backend:49a30cd2 (digest sha256:9b26d456616f3f8b75a8e26b7d520cbfa877e841a9e642a59fc2220b0cd8c5f1)
- Prior :stable digest: sha256:f99606b7352436253ea5781dae3719c3c4d8343ed6f0dd24fabb8d3e5305c589
- Box was serving BACKEND_IMAGE_TAG=0af38bd1 before this run.
- Pre-deploy snapshot: axiome-production-predeploy-20261120061848
- MIGRATION_FACTS: SERVICE=organization-service SCHEMA_VERSION=20261119120000_add_analysis_template_version_workflow APPLIED=17 PRE_COUNTS=1654 POST_COUNTS=1654
- MIGRATION_FACTS: SERVICE=user-service SCHEMA_VERSION=20261119130000_grant_workflow_save APPLIED=4 PRE_COUNTS=65 POST_COUNTS=69
- Readiness PASS (https://platform.axiomebio.com/api/v1/health/ready = 200).
- Advanced :stable to 49a30cd2.
- Baseline verification: MISMATCH (warning only — does not roll back). See the deploy log for the expected/actual table.

**Outcome:** completed
