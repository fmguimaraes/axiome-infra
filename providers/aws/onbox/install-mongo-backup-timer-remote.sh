#!/usr/bin/env bash
# providers/aws/onbox/install-mongo-backup-timer-remote.sh — the ON-BOX half
# of the mongo-backup timer conversion (FR32/FR52, AC45). NOT shipped to the
# box (not in providers/aws/onbox/publish-manifest.txt, not an
# aws_s3_object): providers/aws/scripts/install-mongo-backup-timer.sh reads
# this file's content and sends it as SSM command TEXT, exactly as the
# previous inline heredoc string did — this file exists only so the exact
# same logic can be run and tested LOCALLY, with systemctl/cron stubbed,
# with no SSM/box involved. Running this file directly on a non-Ubuntu
# machine (a developer's laptop, CI) touches nothing real unless you also
# point MONGO_BACKUP_TIMER_SRC_DIR/_DEST_DIR/_CRON_FILE somewhere real.
#
# Idempotent (FR52/AC45):
#   - unit files are copied only if their content actually differs from
#     what's installed (`cmp`); `daemon-reload` runs at most once, only
#     when something changed. A second run with nothing changed says so
#     and still leaves exactly one timer enabled.
#   - the pre-existing cron entry is removed ONLY after `systemctl enable
#     --now` is verified (is-enabled AND is-active) to have actually taken
#     — never on enable's exit code alone. If enabling fails, or the
#     verification fails, the cron entry is left exactly as it was and
#     this script exits non-zero with systemd's own output, so mongo-backup
#     keeps running on cron until a retry succeeds.
set -euo pipefail

SRC_DIR="${MONGO_BACKUP_TIMER_SRC_DIR:-/opt/axiome}"
DEST_DIR="${MONGO_BACKUP_TIMER_DEST_DIR:-/etc/systemd/system}"
CRON_FILE="${MONGO_BACKUP_TIMER_CRON_FILE:-/etc/cron.d/mongo-backup}"
SERVICE_NAME="mongo-backup.service"
UNIT_NAME="mongo-backup.timer"

for f in "$SERVICE_NAME" "$UNIT_NAME"; do
  [ -f "${SRC_DIR}/${f}" ] || {
    echo "ERROR: ${SRC_DIR}/${f} not pulled yet -- run asset-sync.sh pull first" >&2
    exit 1
  }
done

changed=0
for f in "$SERVICE_NAME" "$UNIT_NAME"; do
  if [ -f "${DEST_DIR}/${f}" ] && cmp -s "${SRC_DIR}/${f}" "${DEST_DIR}/${f}"; then
    continue
  fi
  cp "${SRC_DIR}/${f}" "${DEST_DIR}/${f}"
  changed=1
done

if [ "$changed" -eq 1 ]; then
  systemctl daemon-reload
  echo "unit file(s) updated; daemon reloaded."
else
  echo "unit files unchanged; no daemon-reload needed."
fi

# Enable (+ start) the timer. Capture the real exit status on its own line
# (never `if ! cmd; then rc=$?` — under `set -e` that line would also abort
# before `rc=$?` ever ran, and even without `-e` it reads the NEGATED
# status) — `cmd || rc=$?` is the form that is both `set -e`-safe and
# correct: when `cmd` fails, `$?` inside the `|| rc=$?` arm is still cmd's
# own exit status.
rc=0
enable_out="$(systemctl enable --now "$UNIT_NAME" 2>&1)" || rc=$?
if [ "$rc" -ne 0 ]; then
  echo "ERROR: 'systemctl enable --now ${UNIT_NAME}' failed (rc=${rc}): ${enable_out}" >&2
  echo "ERROR: the cron entry at ${CRON_FILE} is left in place — mongo-backup remains on cron only. Fix the error above and re-run this installer." >&2
  exit 1
fi

# Never trust enable's own exit code alone to mean "running now" — verify
# both facts independently before touching the cron entry.
if ! systemctl is-enabled --quiet "$UNIT_NAME"; then
  echo "ERROR: ${UNIT_NAME} is not enabled even though 'systemctl enable --now' reported success — the cron entry at ${CRON_FILE} is left in place. Run 'systemctl status ${UNIT_NAME}' on the box and retry." >&2
  exit 1
fi
if ! systemctl is-active --quiet "$UNIT_NAME"; then
  echo "ERROR: ${UNIT_NAME} is not active even though 'systemctl enable --now' reported success — the cron entry at ${CRON_FILE} is left in place. Run 'systemctl status ${UNIT_NAME}' on the box and retry." >&2
  exit 1
fi

# Only now — timer verified enabled AND active — is it safe to drop cron.
if [ -e "$CRON_FILE" ]; then
  rm -f "$CRON_FILE"
  echo "${UNIT_NAME} verified enabled and active; removed cron entry ${CRON_FILE}."
else
  echo "${UNIT_NAME} verified enabled and active; no cron entry present (already removed)."
fi

systemctl list-timers "$UNIT_NAME" --no-pager || true
