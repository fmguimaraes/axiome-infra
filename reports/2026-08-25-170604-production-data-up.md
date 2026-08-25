# Power op — production / data-up

- **When (UTC):** 2026-08-25T17:06:04Z
- **Actor:** arn:aws:iam::225201317100:user/axiome-terraform
- **Region:** eu-west-3


## Before

- RDS axiome-production-pg: stopped
- Redis axiome-production-redis: absent

## Actions

- RDS axiome-production-pg: start requested.
- Redis axiome-production-redis: recreating from snapshot axiome-production-redis-final-20260821-0709.

## After

- RDS axiome-production-pg: available
- Redis axiome-production-redis: available
- **Next:** re-enable terraform-cd (a plan should show NO changes).
