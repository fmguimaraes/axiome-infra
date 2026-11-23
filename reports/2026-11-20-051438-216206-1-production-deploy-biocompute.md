# production / deploy-biocompute

- **When (UTC):** 2026-11-20T05:14:38Z
- **Actor:** arn:aws:iam::225201317100:user/axiome-terraform
- **Inputs:**
  - tag=1ce3a89f
  - digest=sha256:d74f90cf93cda17668beb49241fa47c8577b76567507cf2e02a7c8ab180795b5
  - prior_tag=4a5d3364

- Source image: axiome/biocompute:1ce3a89f (digest sha256:d74f90cf93cda17668beb49241fa47c8577b76567507cf2e02a7c8ab180795b5)
- Prior :stable digest: sha256:a06d5f7999655c6caf5f068d15ace06cf60ab6aa9e75201f2cdfdb9c7878fe75
- Box was serving BIOCOMPUTE_IMAGE_TAG=4a5d3364 before this run.
- biocompute carries no schema (EC13) — no snapshot step.
- Readiness PASS (https://platform.axiomebio.com/api/v1/health = 200).
- Advanced :stable to 1ce3a89f.

**Outcome:** completed
