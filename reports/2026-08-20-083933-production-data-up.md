# Power op — production / data-up

- **When (UTC):** 2026-08-20T08:39:33Z
- **Actor:** arn:aws:iam::225201317100:user/axiome-terraform
- **Region:** eu-west-3


## Before

- RDS axiome-production-pg: starting
- Redis axiome-production-redis: absent

## Actions

- RDS axiome-production-pg: not started (state starting).
- Redis axiome-production-redis: recreating from snapshot axiome-production-redis-final-20260813-0939.

## After

- RDS axiome-production-pg: available
- Redis axiome-production-redis: available
- **Next:** re-enable terraform-cd (a plan should show NO changes).
