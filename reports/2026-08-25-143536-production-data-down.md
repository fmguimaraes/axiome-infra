# Power op — production / data-down

- **When (UTC):** 2026-08-25T14:35:36Z
- **Actor:** arn:aws:iam::225201317100:user/axiome-terraform
- **Region:** eu-west-3


## Before

- RDS axiome-production-pg: available
- Redis axiome-production-redis: absent

## Actions

- RDS axiome-production-pg: stop requested (auto-restarts after 7d).
- Redis axiome-production-redis: skipped (state absent).

## After

- RDS axiome-production-pg: stopping
- Redis axiome-production-redis: absent
- **Reminder:** keep terraform-cd gated until 'up'.
