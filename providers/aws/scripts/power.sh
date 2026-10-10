#!/usr/bin/env bash
# power.sh — daily compute on/off for an Axiome AWS environment.
#
# SCOPE (deliberate — do not widen):
#   Stops/starts ONLY the EC2 compute instance. It NEVER touches storage:
#   RDS, ElastiCache, S3, and the Terraform state backend all stay up. The
#   instance's EBS root volume (Mongo / RabbitMQ / local-Redis docker volumes)
#   survives a stop, so no data moves and nothing is snapshotted — EXCEPT the
#   event store (Mongo), which this script now backs up and verifies before
#   every stop (FR31): a stop is the moment that volume becomes unreachable
#   for the rest of the park window, so a backup taken "whenever cron gets to
#   it" (02:00 UTC) could be up to 24h stale at exactly the moment the box
#   goes down.
#
# On start, the box brings itself back: cloud-init installed an enabled
#   `axiome.service` systemd unit (docker compose up -d) and every container is
#   restart: unless-stopped. Images already live on EBS, so there is no ECR
#   pull — start is boot + container warm-up only.
#
# Usage:  ./power.sh <dev|staging|production> <up|down|status>
#         ./power.sh <dev|staging|production> down --skip-backup "<reason>"
#           (FR31 override — compute is stopped WITHOUT a verified backup;
#           the reason is written to the audit report. No secret-shaped
#           reason is accepted, same spirit as scripts/lock.sh's override.)
# Env overrides: AWS_REGION, AXIOME_PROJECT, AXIOME_HEALTH_URL, REPORTS_DIR,
#                BACKUP_SSM_WAIT (seconds, default 180),
#                POWER_UP_HEALTH_TIMEOUT_SECONDS (default 600),
#                POWER_UP_HEALTH_POLL_INTERVAL (seconds, default 5)
set -euo pipefail

usage() {
  echo "usage: $0 <dev|staging|production> <up|down|status> [--skip-backup <reason>]" >&2
  exit 2
}
[ $# -ge 2 ] || usage
ENV="$1"; ACTION="$2"; shift 2
case "$ENV" in dev|staging|production) ;; *) usage ;; esac
case "$ACTION" in up|down|status) ;; *) usage ;; esac

SKIP_BACKUP=0
SKIP_REASON=""
while [ $# -gt 0 ]; do
  case "$1" in
    --skip-backup) SKIP_BACKUP=1; SKIP_REASON="${2:-}"; shift 2 ;;
    *) usage ;;
  esac
done
[ "$SKIP_BACKUP" = "1" ] && [ "$ACTION" != "down" ] && usage

PROJECT="${AXIOME_PROJECT:-axiome}"
REGION="${AWS_REGION:-eu-west-3}"
BACKUP_SSM_WAIT="${BACKUP_SSM_WAIT:-180}"

# run_and_verify_backup() parses head-object's JSON with jq (ssm-exec.sh,
# which this script also calls, already requires it — same dependency, not
# a new one for this box).
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required (brew/apt install jq)." >&2; exit 1; }

# Shared reporting/audit helpers. Reports land at the repo root of whatever
# checkout/worktree this runs from, versioned alongside the code.
# shellcheck source=_power_lib.sh
. "$(cd "$(dirname "$0")" && pwd)/_power_lib.sh"

# Readiness endpoint = the app's REAL readiness check (FR26), reached through
# the public edge (CloudFront -> Caddy -> gateway). /health/ready is a 503
# while the database/schema/any backend service is not yet healthy — the poll
# loop below treats that exactly like "not up yet" (EC12: never a false 200),
# not like a hard failure, until the deadline.
case "$ENV" in
  production) FQDN="platform.axiomebio.com" ;;
  staging)    FQDN="staging.axiomebio.com" ;;
  dev)        FQDN="dev.axiomebio.com" ;;
esac
HEALTH_URL="${AXIOME_HEALTH_URL:-https://${FQDN}/api/v1/health/ready}"

# --- NFR3: minimal secret-shape guard for the operator-supplied --skip-backup
# reason. Deliberately duplicated (not sourced) from scripts/lib/report.sh's
# _report_is_secret: that file also defines report_init/report_line/etc, and
# this script already sources providers/aws/scripts/_power_lib.sh for ITS
# same-named functions — sourcing both would silently let the second source
# win and redefine the first's functions. Keeping this check local and
# read-only (it never writes anything) avoids that collision entirely.
# Reviewed and kept as-is at AXI-1951 bounce #1: the two report libraries
# (_power_lib.sh here vs power-data.sh's scripts/lib/report.sh) stay split;
# this duplication is the accepted cost of that split, not an oversight. ---
_looks_like_secret() {
  local s="$1" matched=0
  shopt -s nocasematch
  if [[ "$s" =~ password[[:space:]]*= ]] || [[ "$s" =~ secret[[:space:]]*= ]] ||
     [[ "$s" =~ token[[:space:]]*= ]] || [[ "$s" =~ --password[[:space:]]+[^[:space:]] ]] ||
     [[ "$s" =~ postgres(ql)?://[^[:space:]/@]+:[^[:space:]/@]+@ ]] ||
     [[ "$s" =~ bearer[[:space:]]+[A-Za-z0-9._~+/-]{10,} ]] ||
     [[ "$s" =~ (akia|asia)[0-9a-z]{16} ]]; then
    matched=1
  fi
  shopt -u nocasematch
  [ "$matched" -eq 1 ]
}

# --- resolve the single compute instance by tag (provider default_tags) --------
find_instance() {
  aws ec2 describe-instances --region "$REGION" \
    --filters "Name=tag:Project,Values=${PROJECT}" \
              "Name=tag:Environment,Values=${ENV}" \
              "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[].Instances[].InstanceId' --output text
}

IID="$(find_instance)"
[ -n "$IID" ] || { echo "no EC2 instance for ${PROJECT}/${ENV} in ${REGION}" >&2; exit 1; }
[ "$(printf '%s' "$IID" | wc -w)" -eq 1 ] || {
  echo "expected exactly one instance, found: ${IID}" >&2
  echo "(a deploy may be replacing the VM — retry once it settles)" >&2
  exit 1
}

state() {
  aws ec2 describe-instances --region "$REGION" --instance-ids "$IID" \
    --query 'Reservations[].Instances[].State.Name' --output text
}

# --- FR31: run the on-box backup over SSM, then independently verify the
# object exists in the backup bucket from the admin side (never just trust
# the on-box script's own claim). Prints the verified S3 key on stdout on
# success; prints nothing and returns non-zero on any failure.
#
# Bounce #1 fixes:
#   - strict parse: the OK line is accepted only as a WHOLE LINE of the
#     remote command's stdout, in the exact documented format (key then a
#     64-hex-char sha256) — never a substring match against stdout+stderr
#     noise. Captures ssm-exec.sh's stdout and stderr SEPARATELY so the
#     parse only ever sees what the on-box script itself printed.
#   - freshness/integrity: a `head-object` alone is not proof of a backup
#     taken NOW. This also checks the object is non-empty (ContentLength >
#     0), that its LastModified is not older than the moment THIS call
#     issued the backup command (never trust a stale object left over from
#     a previous run), and that the sha256 the on-box script claimed on its
#     OK line matches the sha256 it stored as S3 object metadata at upload
#     (mongo-backup.sh's `aws s3 cp --metadata sha256=...`) — a mismatch
#     between the two is treated exactly like any other verification
#     failure, never masked. -----------------------------------------------
run_and_verify_backup() {
  local ssm out key bucket issued_epoch errfile head_json size last_mod \
        last_mod_epoch meta_sha claimed_sha ok_line
  ssm="${REPO_ROOT}/scripts/ssm-exec.sh"
  [ -x "$ssm" ] || { echo "ssm-exec.sh not found at ${ssm}" >&2; return 1; }

  issued_epoch="$(date -u +%s)"
  errfile="$(mktemp)"
  if ! out="$("$ssm" -e "$ENV" -t "${BACKUP_SSM_WAIT}" "/opt/axiome/scripts/mongo-backup.sh" 2>"$errfile")"; then
    echo "backup command failed: $(cat "$errfile")" >&2
    rm -f "$errfile"
    return 1
  fi
  rm -f "$errfile"

  ok_line="$(printf '%s\n' "$out" | grep -E '^MONGO_BACKUP_OK key=[^[:space:]]+ sha256=[0-9a-f]{64}$' | tail -1)"
  [ -n "$ok_line" ] || { echo "backup did not report success: ${out}" >&2; return 1; }

  key="$(printf '%s' "$ok_line" | sed -n 's/^MONGO_BACKUP_OK key=\([^ ]*\) sha256=.*/\1/p')"
  claimed_sha="$(printf '%s' "$ok_line" | sed -n 's/^MONGO_BACKUP_OK key=[^ ]* sha256=\([0-9a-f]*\)$/\1/p')"
  [ -n "$key" ] && [ -n "$claimed_sha" ] || { echo "could not parse the backup key/sha256 from: ${ok_line}" >&2; return 1; }

  bucket="${AXIOME_SYSTEM_BUCKET:-${PROJECT}-${ENV}-system}"
  head_json="$(aws s3api head-object --region "$REGION" --bucket "$bucket" --key "$key" --output json 2>/dev/null)" || {
    echo "head-object verification of s3://${bucket}/${key} failed (object not confirmed present)" >&2
    return 1
  }

  size="$(printf '%s' "$head_json" | jq -r '.ContentLength // 0' 2>/dev/null)"
  case "$size" in '' | *[!0-9]*) size=0 ;; esac
  [ "$size" -gt 0 ] || { echo "s3://${bucket}/${key} is zero-byte (ContentLength=${size}) — refusing to trust this backup" >&2; return 1; }

  last_mod="$(printf '%s' "$head_json" | jq -r '.LastModified // ""' 2>/dev/null)"
  last_mod_epoch="$(date -u -d "${last_mod}" +%s 2>/dev/null || echo "")"
  [ -n "$last_mod_epoch" ] || { echo "s3://${bucket}/${key} has no readable LastModified — refusing to trust this backup" >&2; return 1; }
  [ "$last_mod_epoch" -ge "$issued_epoch" ] || { echo "s3://${bucket}/${key} LastModified (${last_mod}) predates when this backup was issued — stale object, refusing to trust it" >&2; return 1; }

  meta_sha="$(printf '%s' "$head_json" | jq -r '.Metadata.sha256 // ""' 2>/dev/null)"
  [ -n "$meta_sha" ] || { echo "s3://${bucket}/${key} carries no sha256 metadata — cannot verify checksum" >&2; return 1; }
  [ "$meta_sha" = "$claimed_sha" ] || { echo "s3://${bucket}/${key} sha256 metadata (${meta_sha}) does not match the reported checksum (${claimed_sha}) — checksum mismatch, refusing to trust this backup" >&2; return 1; }

  printf '%s' "$key"
}

case "$ACTION" in
  status)
    echo "${ENV} compute ${IID}: $(state)"
    ;;

  down)
    report_init "$ENV" "compute-down"
    report_section "Before"; report_line "EC2 ${IID}: $(state)"

    report_section "Backup verification (FR31)"
    if [ "$SKIP_BACKUP" = "1" ]; then
      if [ -z "$SKIP_REASON" ]; then
        echo "ERROR: --skip-backup requires a reason" >&2
        report_line "ABORTED: --skip-backup given with no reason."
        report_finish
        exit 1
      fi
      if _looks_like_secret "$SKIP_REASON"; then
        echo "ERROR: --skip-backup reason looks secret-shaped (contains password=/secret=/token=/a bearer token/an AWS-style key/etc) — rephrase and retry." >&2
        report_line "ABORTED: --skip-backup reason rejected (secret-shaped text)."
        report_finish
        exit 1
      fi
      report_line "OVERRIDE skip-backup: ${SKIP_REASON}"
      echo "WARNING: skipping backup verification (--skip-backup): ${SKIP_REASON}" >&2
    else
      BACKUP_KEY="$(run_and_verify_backup)" && BACKUP_RC=0 || BACKUP_RC=$?
      if [ "$BACKUP_RC" -eq 0 ] && [ -n "$BACKUP_KEY" ]; then
        report_line "Mongo backup verified present: key=${BACKUP_KEY}."
      else
        report_line "Mongo backup FAILED or could not be verified — compute NOT stopped (FR31). Re-run with --skip-backup \"<reason>\" to override (audited)."
        report_finish
        echo "ABORT: backup not verified; compute NOT stopped. Use --skip-backup \"<reason>\" to override." >&2
        exit 1
      fi
    fi

    echo "stopping compute ${IID} (${ENV}) — RDS / ElastiCache / S3 / state untouched"
    aws ec2 stop-instances --region "$REGION" --instance-ids "$IID" >/dev/null
    aws ec2 wait instance-stopped --region "$REGION" --instance-ids "$IID"
    log_event "$ENV" "EC2 ${IID}" "compute stopped"
    report_section "Actions"
    report_line "Stopped EC2 ${IID}. RDS / ElastiCache / S3 / state deliberately untouched."
    report_section "After"; report_line "EC2 ${IID}: $(state)"
    report_finish
    echo "stopped."
    ;;

  up)
    report_init "$ENV" "compute-up"
    report_section "Before"; report_line "EC2 ${IID}: $(state)"
    start_epoch="$(date +%s)"
    echo "starting compute ${IID} (${ENV})"
    aws ec2 start-instances --region "$REGION" --instance-ids "$IID" >/dev/null
    aws ec2 wait instance-running --region "$REGION" --instance-ids "$IID"
    # Pre-launch escape hatch: when the public FQDN has no DNS yet, the public
    # health poll can never pass. Callers that validate readiness another way
    # (e.g. power-up-all.sh via on-box SSM) set this to skip the public poll.
    if [ "${AXIOME_SKIP_PUBLIC_HEALTH:-0}" = "1" ]; then
      ttr=$(( $(date +%s) - start_epoch ))
      log_event "$ENV" "EC2 ${IID}" "compute started, public health poll skipped, time-to-running ${ttr}s"
      report_section "Actions"
      report_line "Started EC2 ${IID}; public health poll SKIPPED (AXIOME_SKIP_PUBLIC_HEALTH=1)."
      report_line "**time-to-running: ${ttr}s**"
      report_section "After"; report_line "EC2 ${IID}: $(state)"
      report_finish
      echo "RUNNING (public health poll skipped). time-to-running: ${ttr}s"
      exit 0
    fi
    health_timeout="${POWER_UP_HEALTH_TIMEOUT_SECONDS:-600}"
    echo "instance running; polling ${HEALTH_URL} for app readiness (FR26, timeout ${health_timeout}s)..."
    deadline=$(( start_epoch + health_timeout ))
    until curl -fsS -o /dev/null --max-time 5 "$HEALTH_URL"; do
      [ "$(date +%s)" -lt "$deadline" ] || {
        body="$(curl -sS --max-time 5 "$HEALTH_URL" 2>/dev/null || echo '(unreachable)')"
        report_section "Actions"
        report_line "Started EC2 ${IID} but app NOT READY after ${health_timeout}s. Last /health/ready response: ${body}"
        report_finish
        echo "NOT READY after ${health_timeout}s. Last /health/ready response: ${body}" >&2
        echo "check the box: ssm-exec.sh -e ${ENV} 'docker compose -f /opt/axiome/docker-compose.yml ps'" >&2
        exit 1
      }
      sleep "${POWER_UP_HEALTH_POLL_INTERVAL:-5}"
    done
    ttu=$(( $(date +%s) - start_epoch ))
    log_event "$ENV" "EC2 ${IID}" "compute started, time-to-up ${ttu}s"
    report_section "Actions"
    report_line "Started EC2 ${IID}; app served ${HEALTH_URL} (HTTP 200)."
    report_line "**time-to-up: ${ttu}s**"
    report_section "After"; report_line "EC2 ${IID}: $(state)"
    report_finish
    echo "READY. time-to-up: ${ttu}s"
    ;;

  *) usage ;;
esac
