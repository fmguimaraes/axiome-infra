# Power op — production / turn-on

- **When (UTC):** 2026-08-25T17:06:02Z
- **Actor:** arn:aws:iam::225201317100:user/axiome-terraform
- **Region:** eu-west-3


## Turn-on sequence

- Actor arn:aws:iam::225201317100:user/axiome-terraform
- Data tier: data-up completed (RDS started; Redis restored if it was absent).
- Compute: EC2 up; public health gate passed (HTTP 200 via platform.axiomebio.com).

## Next (before un-gating terraform-cd)

- Run: cd providers/aws && scripts/deploy.sh production --plan-only  # expect NO changes (Redis re-adopted by id/config)
- Only after a clean plan, allow terraform-cd apply again.
