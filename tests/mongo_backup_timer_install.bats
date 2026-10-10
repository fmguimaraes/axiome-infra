#!/usr/bin/env bats
# tests/mongo_backup_timer_install.bats — FR52/AC45: the backup-timer
# installer is idempotent, removes the earlier cron entry ONLY after the
# timer is verified enabled, and is covered by offline tests with
# `systemctl`/cron stubbed. Runs the REAL script,
# providers/aws/onbox/install-mongo-backup-timer-remote.sh — not a fixture
# that prints the expected lines — with MONGO_BACKUP_TIMER_SRC_DIR/
# _DEST_DIR/_CRON_FILE pointed at per-test tmp directories (no SSM, no real
# systemd/cron ever touched). UT-INFRA-465..472.

load 'helpers/setup'

refute_stub_called_with() {
  local name="$1" needle="$2"
  run awk -v n="$name" -v needle="$needle" '
    /^### CALL: /{cur=($0=="### CALL: " n)}
    cur && index($0, needle) {found=1}
    END{exit !found}
  ' "$STUB_LOG"
  [ "$status" -ne 0 ] || fail "expected NO call to '${name}' containing '${needle}' but one was recorded in ${STUB_LOG}"
}

count_stub_calls_with() {
  local name="$1" needle="$2"
  awk -v n="$name" -v needle="$needle" '
    /^### CALL: /{cur=($0=="### CALL: " n); if (cur) block++}
    cur && index($0, needle) {matched[block]=1}
    END{c=0; for (b in matched) c++; print c}
  ' "$STUB_LOG"
}

setup() {
  stub_setup
  export MONGO_BACKUP_TIMER_SRC_DIR="${BATS_TEST_TMPDIR}/src"
  export MONGO_BACKUP_TIMER_DEST_DIR="${BATS_TEST_TMPDIR}/dest"
  export MONGO_BACKUP_TIMER_CRON_FILE="${BATS_TEST_TMPDIR}/cron.d/mongo-backup"
  mkdir -p "$MONGO_BACKUP_TIMER_SRC_DIR" "$MONGO_BACKUP_TIMER_DEST_DIR" "$(dirname "$MONGO_BACKUP_TIMER_CRON_FILE")"
  printf '[Service]\nExecStart=/opt/axiome/scripts/mongo-backup.sh\n' > "${MONGO_BACKUP_TIMER_SRC_DIR}/mongo-backup.service"
  printf '[Timer]\nOnCalendar=*-*-* 02:00:00\n' > "${MONGO_BACKUP_TIMER_SRC_DIR}/mongo-backup.timer"
  printf '0 2 * * * root /opt/axiome/scripts/mongo-backup.sh\n' > "$MONGO_BACKUP_TIMER_CRON_FILE"
  REMOTE_SCRIPT="${INFRA_ROOT}/providers/aws/onbox/install-mongo-backup-timer-remote.sh"
}

# UT-INFRA-465: fresh install — copies both unit files, reloads the daemon
# once, enables+starts the timer, then removes the (present) cron entry.
@test "UT-INFRA-465: fresh install copies units, reloads once, enables the timer and removes cron" {
  stub_use_rules systemctl "${TESTS_DIR}/fixtures/systemctl-enable-ok.rules.sh"

  run "$REMOTE_SCRIPT"

  assert_success
  [ -f "${MONGO_BACKUP_TIMER_DEST_DIR}/mongo-backup.service" ]
  [ -f "${MONGO_BACKUP_TIMER_DEST_DIR}/mongo-backup.timer" ]
  [ ! -e "$MONGO_BACKUP_TIMER_CRON_FILE" ]
  [ "$(count_stub_calls_with systemctl 'daemon-reload')" -eq 1 ]
  assert_stub_called systemctl "enable"
}

# UT-INFRA-466: second run, nothing changed — reports "unchanged", does
# NOT call daemon-reload again, and exactly one timer is (still) enabled.
@test "UT-INFRA-466: second run with no unit changes reports unchanged and skips daemon-reload" {
  stub_use_rules systemctl "${TESTS_DIR}/fixtures/systemctl-enable-ok.rules.sh"

  run "$REMOTE_SCRIPT"
  assert_success

  : > "$STUB_LOG"
  run "$REMOTE_SCRIPT"

  assert_success
  assert_output --partial "unit files unchanged"
  refute_stub_called_with systemctl "daemon-reload"
  assert_stub_called systemctl "enable"
}

# UT-INFRA-467: unit file content changed since the last install — copies
# it, reloads the daemon exactly once, and says units were updated.
@test "UT-INFRA-467: a changed unit file is re-copied and the daemon reloaded exactly once" {
  stub_use_rules systemctl "${TESTS_DIR}/fixtures/systemctl-enable-ok.rules.sh"
  run "$REMOTE_SCRIPT"
  assert_success

  printf '[Timer]\nOnCalendar=*-*-* 03:00:00\n' > "${MONGO_BACKUP_TIMER_SRC_DIR}/mongo-backup.timer"
  : > "$STUB_LOG"
  run "$REMOTE_SCRIPT"

  assert_success
  assert_output --partial "unit file(s) updated"
  [ "$(count_stub_calls_with systemctl 'daemon-reload')" -eq 1 ]
  grep -q "03:00:00" "${MONGO_BACKUP_TIMER_DEST_DIR}/mongo-backup.timer"
}

# UT-INFRA-468: `systemctl enable --now` itself fails — the cron entry is
# left in place, the installer exits non-zero, and never even checks
# is-enabled/is-active (refuses right after the failure it already has).
@test "UT-INFRA-468: enable failure leaves the cron entry in place and exits non-zero" {
  stub_use_rules systemctl "${TESTS_DIR}/fixtures/systemctl-enable-fails.rules.sh"

  run "$REMOTE_SCRIPT"

  assert_failure
  [ -f "$MONGO_BACKUP_TIMER_CRON_FILE" ]
  assert_output --partial "cron entry at ${MONGO_BACKUP_TIMER_CRON_FILE} is left in place"
}

# UT-INFRA-469: `enable --now` reports success but the timer is not
# actually active afterwards — the installer catches this independently
# and leaves the cron entry in place rather than trusting enable's rc.
@test "UT-INFRA-469: enable reporting success but the timer being inactive still leaves cron in place" {
  stub_use_rules systemctl "${TESTS_DIR}/fixtures/systemctl-enabled-but-inactive.rules.sh"

  run "$REMOTE_SCRIPT"

  assert_failure
  [ -f "$MONGO_BACKUP_TIMER_CRON_FILE" ]
  assert_output --partial "is not active"
}

# UT-INFRA-470: cron entry already absent (a prior run already removed it)
# — the installer still succeeds and says so, rather than failing on `rm`.
@test "UT-INFRA-470: an already-absent cron entry does not fail the installer" {
  rm -f "$MONGO_BACKUP_TIMER_CRON_FILE"
  stub_use_rules systemctl "${TESTS_DIR}/fixtures/systemctl-enable-ok.rules.sh"

  run "$REMOTE_SCRIPT"

  assert_success
  assert_output --partial "no cron entry present"
}

# UT-INFRA-471: missing source unit files (never pulled by asset-sync yet)
# refuses before touching systemctl or the cron entry at all.
@test "UT-INFRA-471: missing source unit files refuse before any systemctl call or cron removal" {
  rm -f "${MONGO_BACKUP_TIMER_SRC_DIR}/mongo-backup.timer"

  run "$REMOTE_SCRIPT"

  assert_failure
  assert_output --partial "not pulled yet"
  [ -f "$MONGO_BACKUP_TIMER_CRON_FILE" ]
}

# UT-INFRA-472: mutation check — if the cron entry were removed BEFORE the
# enable verification (the AXI-1951-era ordering), this test would pass
# instead of catching the leak; it is paired with UT-INFRA-468/469 above to
# prove the ordering, not just the final state.
@test "UT-INFRA-472: cron removal never happens before systemctl enable is called" {
  stub_use_rules systemctl "${TESTS_DIR}/fixtures/systemctl-enable-fails.rules.sh"

  run "$REMOTE_SCRIPT"

  assert_failure
  # daemon-reload (unit files are new) then enable --now, which fails —
  # is-enabled/is-active/the cron rm must never follow.
  run grep -c '^### CALL: systemctl$' "$STUB_LOG"
  assert_output "2"
  [ -f "$MONGO_BACKUP_TIMER_CRON_FILE" ]
}

# UT-INFRA-473: the OPERATOR-run entry point, install-mongo-backup-timer.sh,
# sends THIS story's extracted remote script as the SSM command text —
# proving it reads install-mongo-backup-timer-remote.sh rather than some
# other (e.g. the old inline heredoc) text. Sniffs a phrase that only
# exists in the new file.
@test "UT-INFRA-473: install-mongo-backup-timer.sh sends install-mongo-backup-timer-remote.sh as the command text" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed on this host"
  stub_use_rules aws "${TESTS_DIR}/fixtures/install-mongo-backup-timer-aws.rules.sh"
  export SSM_EXEC_POLL_INTERVAL=0

  run "${INFRA_ROOT}/providers/aws/scripts/install-mongo-backup-timer.sh" dev

  assert_success
  run grep -F "unit files unchanged; no daemon-reload needed." "$STUB_LOG"
  assert_success
}
