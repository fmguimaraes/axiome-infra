# Power op — production / compute-up

- **When (UTC):** 2026-11-20T05:03:51Z
- **Actor:** arn:aws:iam::225201317100:user/axiome-terraform
- **Region:** eu-west-3


## Before

- EC2 i-0fce8b81eab806118: stopped

## Actions

- Started EC2 i-0fce8b81eab806118; app served https://platform.axiomebio.com/api/v1/health/ready (HTTP 200).
- **time-to-up: 88s**
- Nightly E2E workflow fmguimaraes/axiome-e2e-testing/prod-e2e-daily.yml: enabled.

## After

- EC2 i-0fce8b81eab806118: running
