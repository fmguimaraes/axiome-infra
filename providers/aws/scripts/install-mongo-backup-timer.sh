#!/usr/bin/env bash
# providers/aws/scripts/install-mongo-backup-timer.sh — ONE-TIME operator
# conversion (FR32), same category as AXI-1950's boot.sh ExecStart
# conversion: moves a box from cron-only mongo-backup (no catch-up) to a
# systemd timer (OnCalendar=daily, Persistent=true — the mechanism that
# actually satisfies "catches up a missed run on box start", see
# providers/aws/onbox/mongo-backup.sh's header). NEVER executed by this
# story, by CI, or against any real box — this story ships the mechanism and
# this script only; running it is an operator act, same as AXI-1950's
# documented boot.sh conversion.
#
# Usage: ./install-mongo-backup-timer.sh <dev|staging|production>
#
# Precondition: the box must already have been converted to the onbox
# asset-sync channel (AXI-1950) and have pulled at least once since this
# story's Terraform published mongo-backup.timer/.service — i.e.
# /opt/axiome/mongo-backup.{timer,service} must already exist on disk
# (delivered by scripts/asset-sync.sh pull, same channel as every other
# onbox file). This script refuses with a clear message if they are absent
# rather than silently doing nothing.
set -euo pipefail

usage() { echo "usage: $0 <dev|staging|production>" >&2; exit 2; }
[ $# -eq 1 ] || usage
ENV="$1"
case "$ENV" in dev|staging|production) ;; *) usage ;; esac

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${HERE}/../../.." && pwd)"
SSM="${REPO_ROOT}/scripts/ssm-exec.sh"
[ -x "$SSM" ] || { echo "ERROR: ssm-exec.sh not found at ${SSM}" >&2; exit 1; }

# Single-quoted heredoc-free literal: no local variable is interpolated into
# the remote command text (NFR3 — nothing secret-shaped ever travels through
# ssm-exec.sh's command-text channel; this command carries no secret at all).
REMOTE_CMD='
set -e
test -f /opt/axiome/mongo-backup.service || { echo "mongo-backup.service not pulled yet -- run asset-sync.sh pull first"; exit 1; }
test -f /opt/axiome/mongo-backup.timer   || { echo "mongo-backup.timer not pulled yet -- run asset-sync.sh pull first"; exit 1; }
cp /opt/axiome/mongo-backup.service /etc/systemd/system/mongo-backup.service
cp /opt/axiome/mongo-backup.timer   /etc/systemd/system/mongo-backup.timer
rm -f /etc/cron.d/mongo-backup
systemctl daemon-reload
systemctl enable --now mongo-backup.timer
systemctl list-timers mongo-backup.timer --no-pager
'

echo "== installing mongo-backup.timer on ${ENV} (one-time conversion) =="
"$SSM" -e "$ENV" -t 60 "$REMOTE_CMD"
echo "done. Verify with: ${REPO_ROOT}/scripts/ssm-exec.sh -e ${ENV} 'systemctl status mongo-backup.timer'"
