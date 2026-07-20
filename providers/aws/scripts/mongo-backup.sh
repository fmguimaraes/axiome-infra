#!/bin/bash
# Daily automated Mongo backup (FR1/FR2/NFR1/NFR4). Deployed to the EC2 host at
# /opt/axiome/scripts/mongo-backup.sh via aws_s3_object (modules/compute-ec2) and
# run by /etc/cron.d/mongo-backup. Restore procedure: docs/restore-procedures.md.
set -euo pipefail
exec >> /var/log/mongo-backup.log 2>&1
echo "=== mongo-backup started at $(date -u +%FT%TZ) ==="

source /opt/axiome/.env

TS=$(date -u +%Y%m%dT%H%M%SZ)
ARCHIVE="/tmp/mongo-backup-$TS.archive.gz"
trap 'rm -f "$ARCHIVE"' EXIT

docker exec axiome-mongo mongodump \
    --username "${MONGO_ROOT_USER:-axiome}" \
    --password "$MONGO_ROOT_PASSWORD" \
    --authenticationDatabase admin \
    --archive --gzip > "$ARCHIVE"

aws s3 cp "$ARCHIVE" "s3://$S3_BUCKET_SYSTEM/backups/mongo/$TS.archive.gz"

echo "=== mongo-backup finished at $(date -u +%FT%TZ) ==="
