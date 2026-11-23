# production / deploy-biocompute

- **When (UTC):** 2026-11-23T23:25:34Z
- **Actor:** arn:aws:iam::225201317100:user/axiome-terraform
- **Inputs:**
  - tag=2e4082e4
  - digest=sha256:63e653c98ef44432a76391f7f7902ab48cbdf7c785ed8884ab7e6bd131a02ae1
  - prior_tag=1ce3a89f

- Source image: axiome/biocompute:2e4082e4 (digest sha256:63e653c98ef44432a76391f7f7902ab48cbdf7c785ed8884ab7e6bd131a02ae1)
- Prior :stable digest: sha256:d74f90cf93cda17668beb49241fa47c8577b76567507cf2e02a7c8ab180795b5
- Box was serving BIOCOMPUTE_IMAGE_TAG=1ce3a89f before this run.
- biocompute carries no schema (EC13) — no snapshot step.
- Readiness PASS (https://platform.axiomebio.com/api/v1/health = 200).
- Advanced :stable to 2e4082e4.

**Outcome:** completed
