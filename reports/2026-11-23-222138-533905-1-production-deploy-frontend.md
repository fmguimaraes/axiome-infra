# production / deploy-frontend

- **When (UTC):** 2026-11-23T22:21:38Z
- **Actor:** arn:aws:iam::225201317100:user/axiome-terraform
- **Inputs:**
  - tag=75abcea1
  - digest=sha256:cea745e45ea3d9109dfd34f863c220383b759755e13be7973ace691c91e43c40
  - prior_tag=06992ae4

- Source image: axiome/frontend:75abcea1 (digest sha256:cea745e45ea3d9109dfd34f863c220383b759755e13be7973ace691c91e43c40)
- Prior :stable digest: sha256:4e0540b5a50293ceac218b9abfdbf22e43ccfe2649b573f2f6a2337dcc4b1e4f
- Box was serving FRONTEND_IMAGE_TAG=06992ae4 before this run.
- frontend carries no schema (EC13) — no snapshot step.
- Readiness PASS (https://platform.axiomebio.com/api/v1/health = 200).
- Advanced :stable to 75abcea1.

**Outcome:** completed
