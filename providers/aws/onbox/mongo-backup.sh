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
# Password handling (FR51/AC44, AXI-1970 — closes the AXI-1951 bounce #1
# debt item): the Mongo root password must never appear on any process's
# argument list — not `docker exec`'s, not `mongodump`'s. `--password
# "$MONGO_ROOT_PASSWORD"` would put it on mongodump's own argv, visible to
# anything with `ps`/`docker top`/`docker inspect` access on the box, even
# though `docker exec` itself never sees it either way. `--username` and
# `--authenticationDatabase` are NOT secrets and stay on mongodump's
# ordinary argv.
#
# Channel chosen: a 0600 HOST-side tempfile (mktemp under a umask-077
# subshell — never a wider-permission file, even for an instant) holding a
# mongodump `--config` YAML document containing ONLY `password:` — VERIFIED
# against a real mongodump binary (mongo:7's bundled tools, review bounce
# #1): the MongoDB Database Tools config file accepts exactly `password`,
# `uri` and `sslPEMKeyPassword`; `username`/`authenticationDatabase` are
# NOT accepted keys there (a prior version of this file put all three in
# the YAML — mongodump silently ignored the two it doesn't recognise and
# every real backup failed on a missing --username/--password, while the
# stubbed test suite stayed green since `docker` was stubbed). See
# `mongodump_password_config_yaml` below (quoting rules documented on it)
# and this story's handback for the throwaway-container verification
# transcript. Deliberately defined IN this file, not a sibling sourced
# file: mongo-backup.sh is delivered to the box as a single standalone
# file over two channels (see above) — a second file would need its own
# delivery entry in both, which this fix does not need.
#
# The YAML file is handed to mongodump as `--config=/dev/stdin`, with the
# container's fd 0 (via `docker exec -i`) redirected FROM that host file —
# so the only things that ever appear on an argv, anywhere, are the
# literal strings `--username`, the (non-secret) user, `--authentication
# Database`, `admin`, `--config=/dev/stdin`, `exec`, `-i`, `axiome-mongo`,
# `mongodump`, `--archive`, `--gzip`. The password is file content, read
# once by mongodump over its own stdin; nothing is ever written INTO the
# container's filesystem (no `docker cp`/second command that would be one
# more place the secret could leak or be left behind). `trap` removes the
# tempfile on every exit path — the normal EXIT trap below, and explicit
# INT/TERM handlers, since a bare `trap ... EXIT` is not guaranteed to run
# for every signal.
#
# Restore procedure: docs/restore-procedures.md.
set -euo pipefail

# mongodump_password_config_yaml <password> — prints a mongodump --config
# YAML document on stdout containing ONLY `password:` (never `username`/
# `authenticationDatabase` — see the header comment above for why those
# stay on mongodump's ordinary argv instead). Quoting: a YAML single-quoted
# scalar's only escape is doubling an embedded `'` (`'` -> `''`) — no
# backslash escaping, so `"`, `\`, `:`, `#`, a leading `*` and a trailing
# space all round-trip untouched (confirmed against PyYAML and a real
# mongodump binary — see this story's handback). A literal newline does
# NOT round-trip (YAML folds it to a space inside a single-quoted scalar)
# — refused rather than silently using the wrong password. Never prints
# the password itself, even on that refusal.
#
# Defined here, not sourced from a sibling file: see the header comment
# above for why. A test sources THIS file with MONGO_BACKUP_LIB_ONLY=1 set
# (the script returns right after this function is defined, before
# touching the log/env file/docker — see below) so it exercises this exact
# function, not a copy.
mongodump_password_config_yaml() {
  local pw="$1" escaped
  case "$pw" in
    *$'\n'*)
      echo "ERROR: MONGO_ROOT_PASSWORD contains a newline, which a mongodump YAML config file cannot represent without corrupting it (YAML folds a newline inside a single-quoted scalar into a space) — refusing rather than silently using the wrong password." >&2
      return 1
      ;;
  esac
  escaped="${pw//\'/\'\'}"
  printf "password: '%s'\n" "$escaped"
}

# Test-only seam (never set in production): let a test `source` this file
# just to get the function above, without running the rest of the script
# (log redirect, env sourcing, docker exec, ...).
if [ -n "${MONGO_BACKUP_LIB_ONLY:-}" ]; then
  return 0
fi

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

# FR51/AC44: the mongodump credentials file. Created with a umask-077
# subshell so the restrictive mode is in force from the FIRST byte written
# (no window where the file briefly carries wider permissions), named so a
# test can find/assert-absent it by glob without knowing the exact mktemp
# suffix. Removed on every exit path: the EXIT trap below (normal return,
# `fail`'s explicit `exit 1`) AND the INT/TERM traps (a bare EXIT trap is
# not guaranteed to fire on every signal in every bash build).
MONGODUMP_CONFIG="$(umask 077 && mktemp "${TMPDIR:-/tmp}/mongo-backup-config.XXXXXX")"
_cleanup() { rm -f "$ARCHIVE" "$MONGODUMP_CONFIG"; }
trap _cleanup EXIT
trap '_cleanup; exit 143' TERM
trap '_cleanup; exit 130' INT

mongodump_password_config_yaml "$MONGO_ROOT_PASSWORD" > "$MONGODUMP_CONFIG" \
  || fail "could not build the mongodump credentials file"

# No pipe is involved here (`>` is a redirect, not a `|`), so `set -o
# pipefail` (part of `set -euo pipefail` above) does not change this check's
# meaning — `||` already reads docker exec's OWN exit status, which is
# mongodump's exit status inside the container. A docker-exec failure after
# some bytes were already written to $ARCHIVE is still caught HERE, by the
# exit code, never by $ARCHIVE's size — the size check below is a SEPARATE,
# additional guard against a technically-zero-exit-but-empty-output case.
#
# `-i` + `< "$MONGODUMP_CONFIG"` wires the container's fd 0 to the host
# tempfile's content; `--config=/dev/stdin` is the only credential-related
# argv element on either `docker exec` or `mongodump` — see the FR51/AC44
# header comment above for why. `--username`/`--authenticationDatabase`
# are ordinary (non-secret) flags, same as before this story.
docker exec -i axiome-mongo mongodump \
    --username "${MONGO_ROOT_USER:-axiome}" \
    --authenticationDatabase admin \
    --config=/dev/stdin \
    --archive --gzip \
    < "$MONGODUMP_CONFIG" > "$ARCHIVE" || fail "mongodump failed"

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
