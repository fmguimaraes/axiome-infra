# Power op — production / data-down

- **When (UTC):** 2026-08-21T07:09:39Z
- **Actor:** arn:aws:iam::225201317100:user/axiome-terraform
- **Region:** eu-west-3


## Before

- RDS axiome-production-pg: available
- Redis axiome-production-redis: available

## Actions

- RDS axiome-production-pg: stop requested (auto-restarts after 7d).
- Redis axiome-production-redis: config -> s3://axiome-production-system/power-data/redis-state.env; final snapshot axiome-production-redis-final-20260821-0709; RG deleting.

## After

- RDS axiome-production-pg: stopping
- Redis axiome-production-redis: deleting
- **Reminder:** keep terraform-cd gated until 'up'.
