# production / deploy-frontend

- **When (UTC):** 2026-11-23T17:44:08Z
- **Actor:** arn:aws:iam::225201317100:user/axiome-terraform
- **Inputs:**
  - tag=06992ae4
  - digest=sha256:4e0540b5a50293ceac218b9abfdbf22e43ccfe2649b573f2f6a2337dcc4b1e4f
  - prior_tag=52b5924b

- Source image: axiome/frontend:06992ae4 (digest sha256:4e0540b5a50293ceac218b9abfdbf22e43ccfe2649b573f2f6a2337dcc4b1e4f)
- Prior :stable digest: sha256:41efb9a7f6235b6402a2eb5c15312d18be7b47d3d7c1ca739c3e349746dff444
- Box was serving FRONTEND_IMAGE_TAG=52b5924b before this run.
- frontend carries no schema (EC13) — no snapshot step.
- Readiness PASS (https://platform.axiomebio.com/api/v1/health = 200).
- Advanced :stable to 06992ae4.

**Outcome:** completed
