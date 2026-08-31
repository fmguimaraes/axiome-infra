# Power op — production / data-down

- **When (UTC):** 2026-08-31T18:35:35Z
- **Actor:** arn:aws:iam::225201317100:user/axiome-terraform
- **Region:** eu-west-3


## Before

- RDS axiome-production-pg: stopped
- Redis axiome-production-redis: absent

## Actions

- RDS axiome-production-pg: skipped (state stopped).
- Redis axiome-production-redis: skipped (state absent).

## After

- RDS axiome-production-pg: stopped
- Redis axiome-production-redis: absent
- **Reminder:** keep terraform-cd gated until 'up'.
