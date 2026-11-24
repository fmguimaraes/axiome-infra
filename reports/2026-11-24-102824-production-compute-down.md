# Power op — production / compute-down

- **When (UTC):** 2026-11-24T10:28:24Z
- **Actor:** arn:aws:iam::225201317100:user/axiome-terraform
- **Region:** eu-west-3


## Before

- EC2 i-0fce8b81eab806118: running

## Backup verification (FR31)

- Mongo backup verified present: key=backups/mongo/20261124T102828Z.archive.gz.

## Actions

- Stopped EC2 i-0fce8b81eab806118. RDS / ElastiCache / S3 / state deliberately untouched.
- Nightly E2E workflow fmguimaraes/axiome-e2e-testing/prod-e2e-daily.yml: disabled.

## After

- EC2 i-0fce8b81eab806118: stopped
