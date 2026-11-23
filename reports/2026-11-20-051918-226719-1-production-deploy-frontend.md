# production / deploy-frontend

- **When (UTC):** 2026-11-20T05:19:18Z
- **Actor:** arn:aws:iam::225201317100:user/axiome-terraform
- **Inputs:**
  - tag=9b3fb4ad
  - digest=sha256:877c896d96aad0615098d94217a9e16195bca5d6b9166427a2bec5eb0eaae6a0
  - prior_tag=dc160ce5

- Source image: axiome/frontend:9b3fb4ad (digest sha256:877c896d96aad0615098d94217a9e16195bca5d6b9166427a2bec5eb0eaae6a0)
- Prior :stable digest: sha256:3b99252a21fc05a30217521d2a3e48f39968fe889bc65e346bd8d54c2cc2a90f
- Box was serving FRONTEND_IMAGE_TAG=dc160ce5 before this run.
- frontend carries no schema (EC13) — no snapshot step.
- Readiness PASS (https://platform.axiomebio.com/ = 200).
- Advanced :stable to 9b3fb4ad.

**Outcome:** completed
