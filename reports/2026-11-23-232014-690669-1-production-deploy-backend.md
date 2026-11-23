# production / deploy-backend

- **When (UTC):** 2026-11-23T23:20:14Z
- **Actor:** arn:aws:iam::225201317100:user/axiome-terraform
- **Inputs:**
  - tag=06b5368c
  - digest=sha256:6526a8237e3d17c5cde5d3bc7b55f198be2fd9d426e2d8b5e8541cd03746ce9c
  - prior_tag=a17f795b

- Source image: axiome/backend:06b5368c (digest sha256:6526a8237e3d17c5cde5d3bc7b55f198be2fd9d426e2d8b5e8541cd03746ce9c)
- Prior :stable digest: sha256:e1e562fc2b45ea82577f991fdba889a99c4a1b697c49730a154204d1f71b3839
- Box was serving BACKEND_IMAGE_TAG=a17f795b before this run.
- Pre-deploy snapshot: axiome-production-predeploy-20261123232017
- MIGRATION_FACTS: SERVICE=organization-service SCHEMA_VERSION=20261119120000_add_analysis_template_version_workflow APPLIED=0 PRE_COUNTS=skipped POST_COUNTS=skipped
- MIGRATION_FACTS: SERVICE=user-service SCHEMA_VERSION=20261123200000_grant_admin_workspace_manage_members APPLIED=1 PRE_COUNTS=126 POST_COUNTS=126
- Readiness PASS (https://platform.axiomebio.com/api/v1/health/ready = 200).
- Advanced :stable to 06b5368c.
- Baseline verification: MISMATCH (warning only — does not roll back). See the deploy log for the expected/actual table.

**Outcome:** completed
