# Power op — production / compute-down

- **When (UTC):** 2026-11-14T16:30:28Z
- **Actor:** arn:aws:iam::225201317100:user/axiome-terraform
- **Region:** eu-west-3


## Before

- EC2 i-0fce8b81eab806118: running

## Backup verification (FR31)

- Mongo backup verified present: key=backups/mongo/20261114T163032Z.archive.gz.

## Actions

- Stopped EC2 i-0fce8b81eab806118. RDS / ElastiCache / S3 / state deliberately untouched.

## After

- EC2 i-0fce8b81eab806118: stopped
