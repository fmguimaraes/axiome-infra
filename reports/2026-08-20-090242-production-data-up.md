# Power op — production / data-up

- **When (UTC):** 2026-08-20T09:02:42Z
- **Actor:** arn:aws:iam::225201317100:user/axiome-terraform
- **Region:** eu-west-3


## Before

- RDS axiome-production-pg: available
- Redis axiome-production-redis: available

## Actions

- RDS axiome-production-pg: already available (skipped).
- Redis axiome-production-redis: not recreated (state available).

## After

- RDS axiome-production-pg: available
- Redis axiome-production-redis: available
- **Next:** re-enable terraform-cd (a plan should show NO changes).
