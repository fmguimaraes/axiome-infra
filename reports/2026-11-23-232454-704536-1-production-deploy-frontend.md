# production / deploy-frontend

- **When (UTC):** 2026-11-23T23:24:54Z
- **Actor:** arn:aws:iam::225201317100:user/axiome-terraform
- **Inputs:**
  - tag=ab36f79f
  - digest=sha256:5f2bd1589ea41c7949e83ff284f4700c295462ea74e07b23b4e43062fcdef5a9
  - prior_tag=75abcea1

- Source image: axiome/frontend:ab36f79f (digest sha256:5f2bd1589ea41c7949e83ff284f4700c295462ea74e07b23b4e43062fcdef5a9)
- Prior :stable digest: sha256:cea745e45ea3d9109dfd34f863c220383b759755e13be7973ace691c91e43c40
- Box was serving FRONTEND_IMAGE_TAG=75abcea1 before this run.
- frontend carries no schema (EC13) — no snapshot step.
- Readiness PASS (https://platform.axiomebio.com/api/v1/health = 200).
- Advanced :stable to ab36f79f.

**Outcome:** completed
