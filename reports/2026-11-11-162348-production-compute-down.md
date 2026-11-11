# Power op — production / compute-down

- **When (UTC):** 2026-11-11T16:23:48Z
- **Actor:** arn:aws:iam::225201317100:user/axiome-terraform
- **Region:** eu-west-3


## Before

- EC2 i-0fce8b81eab806118: running

## Backup verification (FR31)

- OVERRIDE skip-backup: mongo-backup.sh not executable on-box, pre-existing permission bug unrelated to AXI-2490, owner approved skip 2026-11-11

## Actions

- Stopped EC2 i-0fce8b81eab806118. RDS / ElastiCache / S3 / state deliberately untouched.

## After

- EC2 i-0fce8b81eab806118: stopped
