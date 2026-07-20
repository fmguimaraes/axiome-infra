# Restore Procedures — AWS Production (FR1 / FR2 / NFR1 / NFR2 / NFR4)

Per-store restore runbook for the MIPP HDS production stack (`eu-west-3`). Companion
to the backup mechanisms in `providers/aws/modules/{database-rds,cache-redis,storage,
compute-ec2}` and `providers/aws/cloud-init/init.sh.tftpl` (Mongo).

**Restore drills MUST target an isolated resource (a scratch RDS/ElastiCache instance,
a scratch EC2/Mongo container), never production in place.** Record the achieved
RPO/RTO for each drill as an evidence entry under `axiome-docs/reports/infra/`
(FR2/NFR7) — do not hand-edit an existing evidence report; add a new dated record.

## RPO / RTO targets (NFR1, pilot)

| Store | RPO target | RTO target | Backup mechanism |
|---|---|---|---|
| RDS PostgreSQL | ≤ 24 h (PITR: seconds) | ≤ 4 h | Automated backups + PITR, `backup_retention_days` (default 7d) |
| ElastiCache Redis | ≤ 24 h | ≤ 4 h | Automated daily snapshot, `snapshot_retention_days` (default 7d) |
| Event-store MongoDB | ≤ 24 h | ≤ 4 h | Daily `mongodump` → S3 `system` bucket, `backups/mongo/` (cron, 02:00 UTC) |
| S3 (artifacts / uploads / system) | 0 (versioning) | ≤ 1 h | Bucket versioning (all three buckets) |

All backups are CMK-encrypted (NFR4) — RDS/ElastiCache via the data CMK
(`alias/axiome-production-data`); Mongo dumps and S3 objects via the same CMK as the
bucket's default SSE-KMS configuration. All resources stay in `eu-west-3` (NFR2).

## RDS PostgreSQL (PITR)

**Restore (to a scratch instance, for a drill or an actual incident):**

```
aws rds restore-db-instance-to-point-in-time \
    --source-db-instance-identifier axiome-production-pg \
    --target-db-instance-identifier axiome-production-pg-restore-drill \
    --restore-time <ISO8601 timestamp, or --use-latest-restorable-time> \
    --db-subnet-group-name axiome-production-pg \
    --vpc-security-group-ids <data-sg-id> \
    --no-multi-az
```

1. Wait for `DBInstanceStatus = available` (`aws rds describe-db-instances`).
2. Connect via a bastion/SSM-forwarded port; verify row counts / a recent audit-log
   entry against the known-good source.
3. Record the timestamp of the restore request minus the achieved `--restore-time`
   as the demonstrated RPO; the wall-clock to `available` + verification as the RTO.
4. Delete the scratch instance (`aws rds delete-db-instance --skip-final-snapshot`).

## ElastiCache Redis (snapshot)

Redis here is a **cache**, not a system of record (WebSocket pub/sub adapter) — the
drill demonstrates the mechanism works, not data criticality.

```
aws elasticache describe-snapshots --replication-group-id axiome-production-redis
aws elasticache create-replication-group \
    --replication-group-id axiome-production-redis-restore-drill \
    --replication-group-description "restore drill" \
    --snapshot-name <snapshot-name> \
    --cache-subnet-group-name axiome-production-redis \
    --security-group-ids <data-sg-id>
```

1. Wait for `available`; verify a known key via `redis-cli` (TLS, `rediss://`).
2. Record RPO (age of the snapshot used) / RTO (wall-clock to verified `available`).
3. Delete the scratch replication group.

## Event-store MongoDB (mongodump → S3)

Backup: `/opt/axiome/scripts/mongo-backup.sh` (deployed via `aws_s3_object` in
`modules/compute-ec2`, fetched by cloud-init, run daily at 02:00 UTC by
`/etc/cron.d/mongo-backup`). Uploads to
`s3://axiome-production-system/backups/mongo/<UTC-timestamp>.archive.gz`.

**Restore (to a scratch container — never over the live `axiome-mongo` container):**

```bash
# On a scratch host/container with the AWS CLI + mongo tooling available:
aws s3 cp s3://axiome-production-system/backups/mongo/<TS>.archive.gz /tmp/restore.archive.gz
docker run -d --name mongo-restore-drill -p 27018:27017 \
    -e MONGO_INITDB_ROOT_USERNAME=axiome -e MONGO_INITDB_ROOT_PASSWORD=<scratch-password> \
    mongo:7
docker cp /tmp/restore.archive.gz mongo-restore-drill:/tmp/restore.archive.gz
docker exec mongo-restore-drill mongorestore \
    --username axiome --password <scratch-password> --authenticationDatabase admin \
    --archive=/tmp/restore.archive.gz --gzip
```

1. Verify document counts / a known recent event against the source.
2. Record RPO (age of the S3 object vs. the drill start time) / RTO (wall-clock
   through verification).
3. Tear down the scratch container.

**Rollout note:** the mongo-backup cron is installed by `cloud-init/init.sh.tftpl`.
The production EC2 instance is pinned (`user_data_replace_on_change = false`,
`lifecycle.ignore_changes = [ami]`) so a `terraform apply` alone does **not**
retroactively install it on the already-running host — push it once via
`scripts/ssm-exec.sh` (or an equivalent SSM Run Command) after apply.

## S3 (artifacts / uploads / system) — versioning

```
aws s3api list-object-versions --bucket axiome-production-<bucket> --prefix <key>
aws s3api get-object --bucket axiome-production-<bucket> --key <key> \
    --version-id <version-id> restored-object
aws s3api put-object --bucket axiome-production-<bucket> --key <key> \
    --body restored-object   # re-promotes the prior version to current
```

RPO is effectively zero (every write is preserved as a version); RTO is the time to
identify and restore the correct version (target ≤ 1 h).

## Evidence

After each drill, append a dated record to `axiome-docs/reports/infra/` (new file,
`<YYYY-MM-DD>T<HHMMSS>Z__aws__production__<short-sha>__restore-drill.md`) capturing:
store, drill timestamp, snapshot/backup point used, restore start/available/verified
timestamps, computed RPO/RTO vs. target, and teardown confirmation. This is the AC2
evidence artifact — do not hand-edit an existing report (NFR7).
