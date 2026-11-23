# production / deploy-backend

- **When (UTC):** 2026-11-23T22:14:27Z
- **Actor:** arn:aws:iam::225201317100:user/axiome-terraform
- **Inputs:**
  - tag=a17f795b
  - digest=sha256:e1e562fc2b45ea82577f991fdba889a99c4a1b697c49730a154204d1f71b3839
  - prior_tag=a8e8b5e0

- Source image: axiome/backend:a17f795b (digest sha256:e1e562fc2b45ea82577f991fdba889a99c4a1b697c49730a154204d1f71b3839)
- Prior :stable digest: sha256:f38f5143918f3f42d2dd622c7dd62d66b17e08e44abee6bb5a42160da6071e72
- Box was serving BACKEND_IMAGE_TAG=a8e8b5e0 before this run.
- Pre-deploy snapshot: axiome-production-predeploy-20261123221430
- MIGRATION_FACTS: SERVICE=organization-service SCHEMA_VERSION=20261119120000_add_analysis_template_version_workflow APPLIED=0 PRE_COUNTS=skipped POST_COUNTS=skipped
- MIGRATION_FACTS: SERVICE=user-service SCHEMA_VERSION=20261123100000_grant_investigator_governed_execution_approve APPLIED=1 PRE_COUNTS=124 POST_COUNTS=126
- Readiness PASS (https://platform.axiomebio.com/api/v1/health/ready = 200).
- Advanced :stable to a17f795b.
- Baseline verification: MISMATCH (warning only — does not roll back). See the deploy log for the expected/actual table.

**Outcome:** completed
