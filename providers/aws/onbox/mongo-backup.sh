#!/bin/bash
# providers/aws/onbox/mongo-backup.sh — on-box event-store (Mongo) backup +
# verification (FR31/FR32, NFR2/NFR3/NFR4; epic AXI-1944 decision 8).
#
# Delivered to /opt/axiome/scripts/mongo-backup.sh via TWO channels that stay
# in sync by construction (both publish the SAME source file):
#   1. aws_s3_object.mongo_backup_script (modules/compute-ec2, modules/compute)
#      -> key "scripts/mongo-backup.sh", fetched directly by
#      cloud-init/init.sh.tftpl step 12 at first boot (that template is NOT
#      touched by this story).
#   2. The onbox/ asset-sync channel (AXI-1950 decision 8) -> key
#      "onbox/scripts/mongo-backup.sh", pulled into the same on-box path by
#      scripts/asset-sync.sh on every boot/roll and by an operator's one-time
#      conversion — this is what keeps an EXISTING box's copy current without
#      a cloud-init / user_data change.
#
# Run by three triggers:
#   - cron, today: /etc/cron.d/mongo-backup, 02:00 UTC daily (unchanged, not
#     this story's to edit).
#   - providers/aws/scripts/power.sh's pre-stop backup-and-verify step (FR31),
#     invoked over SSM. power.sh reads the command's STANDARD OUTPUT — see
#     the stdout contract below; this is the whole point of the fd-3 trick.
#   - once an operator installs mongo-backup.timer/.service
#     (providers/aws/scripts/install-mongo-backup-timer.sh — delivered by
#     this story, NEVER run live by it): systemd's OnCalendar=daily,
#     Persistent=true. Persistent=true is the actual mechanism that satisfies
#     FR32 ("when the box starts and the last successful backup is older than
#     24 hours, a backup SHALL run") — a systemd timer with Persistent=true
#     fires immediately after boot if the last scheduled run was missed while
#     the box was off. No extra staleness-check logic is needed in THIS
#     script for that path; it only needs to behave correctly whenever it IS
#     invoked, from any of the three triggers above.
#
# Contract — EXACTLY one line on the script's ORIGINAL stdout per run, and
# nothing else on it (power.sh's SSM caller reads only that):
#   success -> "MONGO_BACKUP_OK key=<s3-key> sha256=<hex>"
#   failure -> "MONGO_BACKUP_FAILED <reason>", non-zero exit.
# Full narration (the "=== started/finished ===" lines, WARNs, etc.) goes to
# the log only. The SAME contract line is also written to the log, so an
# operator tailing the log sees the identical fact.
#
# Testability seams (bug fix, AXI-1951 review bounce #1): a prior version did
# `exec >> /var/log/mongo-backup.log 2>&1` unconditionally and then `echo`'d
# the contract lines — which therefore ALSO went only to the log, never to
# the caller's stdout. power.sh (reading the SSM command's stdout) always
# saw an empty string, so it always fell into "backup did not report
# success" and refused the stop — the one thing FR31 is supposed to prevent.
# Fixed by saving the original stdout on fd 3 BEFORE the log redirect, and
# writing the two contract lines to BOTH fd 3 (the real caller) and the
# current stdout (the log). MONGO_BACKUP_LOG / MONGO_BACKUP_ENV_FILE let a
# test point this script at a tmpfile instead of the real on-box paths;
# their defaults are exactly the on-box values, so production behaviour is
# unchanged.
#
# Never masks a failure with `|| true` (NFR2) — every step that can fail is
# checked, including a post-upload head-object verification (a verification
# whose input cannot be read counts as a failure, not a skip). The sha256 is
# also stored as S3 object metadata at upload (power.sh's INDEPENDENT
# verification compares against it — see power.sh's run_and_verify_backup).
#
# Known debt (left as-is per explicit review decision, AXI-1951 bounce #1):
# the Mongo root password appears on `docker exec`'s argv, visible to
# anything with `ps`/`docker inspect` access on the box. Pre-existing before
# this story; not fixed here.
#
# Restore procedure: docs/restore-procedures.md.
set -euo pipefail

LOG_FILE="${MONGO_BACKUP_LOG:-/var/log/mongo-backup.log}"
ENV_FILE="${MONGO_BACKUP_ENV_FILE:-/opt/axiome/.env}"

# Save the REAL caller's stdout (SSM's command stdout, or an interactive
# terminal) on fd 3 before redirecting 1+2 to the log. Every line written
# after this point goes to the log only, UNLESS explicitly also sent to >&3.
exec 3>&1
exec >> "$LOG_FILE" 2>&1
echo "=== mongo-backup started at $(date -u +%FT%TZ) ==="

# emit_contract <line> — the ONLY function allowed to write to fd 3. Writes
# the exact same line to the log (current stdout) and to the real caller.
emit_contract() {
  echo "$1"
  echo "$1" >&3
}

# shellcheck disable=SC1090,SC1091
source "$ENV_FILE"

fail() {
  emit_contract "MONGO_BACKUP_FAILED $1"
  echo "=== mongo-backup FAILED at $(date -u +%FT%TZ): $1 ==="
  exit 1
}

[ -n "${S3_BUCKET_SYSTEM:-}" ] || fail "S3_BUCKET_SYSTEM not set in ${ENV_FILE}"
BUCKET="${S3_BUCKET_SYSTEM}"

TS=$(date -u +%Y%m%dT%H%M%SZ)
ARCHIVE="/tmp/mongo-backup-${TS}.archive.gz"
KEY="backups/mongo/${TS}.archive.gz"
trap 'rm -f "$ARCHIVE"' EXIT

# No pipe is involved here (`>` is a redirect, not a `|`), so `set -o
# pipefail` (part of `set -euo pipefail` above) does not change this check's
# meaning — `||` already reads docker exec's OWN exit status, which is
# mongodump's exit status inside the container. A docker-exec failure after
# some bytes were already written to $ARCHIVE is still caught HERE, by the
# exit code, never by $ARCHIVE's size — the size check below is a SEPARATE,
# additional guard against a technically-zero-exit-but-empty-output case.
docker exec axiome-mongo mongodump \
    --username "${MONGO_ROOT_USER:-axiome}" \
    --password "$MONGO_ROOT_PASSWORD" \
    --authenticationDatabase admin \
    --archive --gzip > "$ARCHIVE" || fail "mongodump failed"

# Non-empty, restorable-shaped check before this script ever uploads it.
[ -s "$ARCHIVE" ] || fail "archive is empty after mongodump"

SHA256="$(sha256sum "$ARCHIVE" | awk '{print $1}')"

aws s3 cp "$ARCHIVE" "s3://${BUCKET}/${KEY}" --metadata "sha256=${SHA256}" \
  || fail "upload to s3://${BUCKET}/${KEY} failed"

# Verify the object really landed (NFR2: a verification whose input cannot be
# read counts as a failure) before this script ever claims success — this is
# the check FR31 requires power-down to be able to rely on. (power.sh's own,
# INDEPENDENT verification over the admin side additionally checks size,
# freshness, and the sha256 metadata written above.)
REMOTE_ETAG="$(aws s3api head-object --bucket "$BUCKET" --key "$KEY" --query ETag --output text 2>/dev/null)" \
  || fail "head-object verification of s3://${BUCKET}/${KEY} failed (object not confirmed present)"
[ -n "${REMOTE_ETAG}" ] && [ "${REMOTE_ETAG}" != "None" ] \
  || fail "head-object returned no ETag for s3://${BUCKET}/${KEY} (object not confirmed present)"

# Latest-backup marker (observability / restore-procedure lookups only). A
# marker-write failure does NOT fail the backup itself — the archive is
# already verified present above, which is the thing FR31 gates on.
MARKER="/tmp/mongo-backup-latest-${TS}.json"
printf '{"timestamp":"%s","key":"%s","sha256":"%s"}\n' "$TS" "$KEY" "$SHA256" > "$MARKER"
if ! aws s3 cp "$MARKER" "s3://${BUCKET}/backups/mongo/latest.json" >/dev/null 2>&1; then
  echo "WARN: could not write backups/mongo/latest.json marker (archive itself is verified; this is observability-only)"
fi
rm -f "$MARKER"

emit_contract "MONGO_BACKUP_OK key=${KEY} sha256=${SHA256}"
echo "=== mongo-backup finished at $(date -u +%FT%TZ) ==="
