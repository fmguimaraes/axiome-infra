# production / deploy-frontend

- **When (UTC):** 2026-11-23T09:20:14Z
- **Actor:** arn:aws:iam::225201317100:user/axiome-terraform
- **Inputs:**
  - tag=52b5924b
  - digest=sha256:41efb9a7f6235b6402a2eb5c15312d18be7b47d3d7c1ca739c3e349746dff444
  - prior_tag=9b3fb4ad

- Source image: axiome/frontend:52b5924b (digest sha256:41efb9a7f6235b6402a2eb5c15312d18be7b47d3d7c1ca739c3e349746dff444)
- Prior :stable digest: sha256:877c896d96aad0615098d94217a9e16195bca5d6b9166427a2bec5eb0eaae6a0
- Box was serving FRONTEND_IMAGE_TAG=9b3fb4ad before this run.
- frontend carries no schema (EC13) — no snapshot step.
- Readiness PASS (https://platform.axiomebio.com/api/v1/health = 200).
- Advanced :stable to 52b5924b.

**Outcome:** completed
