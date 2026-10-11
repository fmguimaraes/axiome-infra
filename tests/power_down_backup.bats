#!/usr/bin/env bats
# tests/power_down_backup.bats — providers/aws/scripts/power.sh <env> down's
# FR31 pre-stop backup-and-verify step. UT-INFRA-180..184, 195..197.

load 'helpers/setup'

setup() {
  stub_setup
  export REPO_ROOT="${INFRA_ROOT}"
  # AXI-1967: power.sh now also sources scripts/lock.sh (for the new
  # deploy/apply FR43 checks below), which transitively sources
  # scripts/lib/report.sh — that file resolves ITS OWN REPORT_REPO_ROOT via
  # `git rev-parse` unless already set. Pre-set it (same pattern as
  # REPO_ROOT above) so this never needs an unconfigured git stub call.
  export REPORT_REPO_ROOT="${INFRA_ROOT}"
  export POWER_NO_COMMIT=1
  export REPORTS_DIR="${BATS_TEST_TMPDIR}/reports"
}

# refute_stub_called_with <name> <substring> — tests/helpers/setup.bash's own
# assert_stub_not_called ignores a second argument (it only checks whether
# <name> was called AT ALL); several assertions below need "aws WAS called,
# but never with THIS specific subcommand" — hence this local helper (mirrors
# assert_stub_called's own awk, inverted), not a change to the shared file.
refute_stub_called_with() {
  local name="$1" needle="$2"
  run awk -v n="$name" -v needle="$needle" '
    /^### CALL: /{cur=($0=="### CALL: " n)}
    cur && index($0, needle) {found=1}
    END{exit !found}
  ' "$STUB_LOG"
  [ "$status" -ne 0 ] || fail "expected NO call to '${name}' containing '${needle}' but one was recorded in ${STUB_LOG}"
}

# UT-INFRA-180: a verified backup allows the stop to proceed.
@test "UT-INFRA-180: power.sh down stops compute only after the backup is verified present (FR31)" {
  stub_use_rules aws "${TESTS_DIR}/fixtures/power-down-backup-ok.rules.sh"

  run "${INFRA_ROOT}/providers/aws/scripts/power.sh" dev down

  assert_success
  assert_stub_called aws "head-object"
  assert_stub_called aws "stop-instances"
}

# UT-INFRA-594 (AXI-1981, FR43): new for this story — a successful down
# acquires its OWN compute lock AND releases it before exiting (via the
# same lock_mark_for_auto_release + lock_install_exit_trap mechanism
# deploy-prod.sh/power-data.sh use) — the lock is not left behind on the
# happy path either.
@test "UT-INFRA-594: power.sh down acquires and then releases the compute lock on a successful run" {
  stub_use_rules aws "${TESTS_DIR}/fixtures/power-down-backup-ok.rules.sh"

  run "${INFRA_ROOT}/providers/aws/scripts/power.sh" dev down
  local power_output="$output"

  assert_success
  assert_stub_called aws "delete-object"
  printf '%s' "$power_output" | grep -qF "RELEASED compute" \
    || fail "expected 'RELEASED compute' in output, got: ${power_output}"
}

# UT-INFRA-181: a failed backup refuses the stop outright (no override given).
@test "UT-INFRA-181: power.sh down refuses to stop compute when the backup fails (FR31)" {
  stub_use_rules aws "${TESTS_DIR}/fixtures/power-down-backup-fail.rules.sh"

  run "${INFRA_ROOT}/providers/aws/scripts/power.sh" dev down

  assert_failure
  assert_output --partial "backup not verified"
  refute_stub_called_with aws "stop-instances"
}

# UT-INFRA-636 (AXI-1981, FR43): new for this story — compute is also
# released when the OPERATION ITSELF fails AFTER the lock was already
# acquired (the backup-verification refusal, UT-INFRA-181's own path) —
# not just on the two "other lock held" refusals above, which release
# before ever reaching the backup step.
@test "UT-INFRA-636: power.sh down releases the compute lock when the backup fails, after having acquired it" {
  stub_use_rules aws "${TESTS_DIR}/fixtures/power-down-backup-fail.rules.sh"

  run "${INFRA_ROOT}/providers/aws/scripts/power.sh" dev down
  local power_output="$output"

  assert_failure
  assert_output --partial "backup not verified"
  assert_stub_called aws "delete-object"
  printf '%s' "$power_output" | grep -qF "RELEASED compute" \
    || fail "expected 'RELEASED compute' in output, got: ${power_output}"
}

# UT-INFRA-182: --skip-backup with a real reason stops anyway, audited.
@test "UT-INFRA-182: power.sh down --skip-backup stops without running the backup, override is audited" {
  stub_use_rules aws "${TESTS_DIR}/fixtures/power-down-backup-ok.rules.sh"

  run "${INFRA_ROOT}/providers/aws/scripts/power.sh" dev down --skip-backup "planned Mongo maintenance window"

  assert_success
  refute_stub_called_with aws "send-command"
  assert_stub_called aws "stop-instances"
  report_file="$(find "${REPORTS_DIR}" -name '*compute-down*.md' | head -1)"
  [ -n "$report_file" ]
  run grep -q "OVERRIDE skip-backup: planned Mongo maintenance window" "$report_file"
  assert_success
}

# UT-INFRA-183: a secret-shaped --skip-backup reason is refused before any
# stop. Restored verbatim from origin/main (review bounce #1) — "token=
# abc123def456" is refused by the sensitive-key-pair branch of
# report_is_secret_value (see UT-INFRA-620 for the dedicated test of that
# branch), not the value-shape branch.
@test "UT-INFRA-183: power.sh down --skip-backup refuses a secret-shaped reason before any stop" {
  stub_use_rules aws "${TESTS_DIR}/fixtures/power-down-backup-ok.rules.sh"

  run "${INFRA_ROOT}/providers/aws/scripts/power.sh" dev down --skip-backup "token=abc123def456"

  assert_failure
  refute_stub_called_with aws "stop-instances"
  refute_stub_called_with aws "send-command"
}

# UT-INFRA-539 (AXI-1973, FR63 rework): power.sh's secret-shape check
# allows an innocuous reason through when it merely mentions a
# sensitive-sounding word as part of a DIFFERENT, whole key
# ("token_ttl", not "token") — the caller-visible behaviour change this
# story makes.
@test "UT-INFRA-539: power.sh down --skip-backup allows an innocuous reason that merely mentions a sensitive-sounding word" {
  stub_use_rules aws "${TESTS_DIR}/fixtures/power-down-backup-ok.rules.sh"

  run "${INFRA_ROOT}/providers/aws/scripts/power.sh" dev down --skip-backup "token_ttl=3600, rotation planned"

  assert_success
  assert_stub_called aws "stop-instances"
  report_file="$(find "${REPORTS_DIR}" -name '*compute-down*.md' | head -1)"
  [ -n "$report_file" ]
  run grep -q "OVERRIDE skip-backup: token_ttl=3600, rotation planned" "$report_file"
  assert_success
}

# UT-INFRA-620 (AXI-1973, FR63 rework, review bounce #1): a --skip-backup
# reason that pairs a WHOLE sensitive key with a real-looking value
# ("token=abc123def456") is refused before any stop; the refusal is
# recorded in the report as an ABORTED line (same shape as the already-
# existing shape-based refusal, UT-INFRA-183), but the offending value is
# never echoed anywhere — not on stdout/stderr, and not in the report file.
@test "UT-INFRA-620: power.sh down --skip-backup refuses a sensitive key=value reason, value never echoed" {
  stub_use_rules aws "${TESTS_DIR}/fixtures/power-down-backup-ok.rules.sh"

  run "${INFRA_ROOT}/providers/aws/scripts/power.sh" dev down --skip-backup "token=abc123def456 rotation planned"

  assert_failure
  refute_stub_called_with aws "stop-instances"
  refute_output --partial "abc123def456"
  report_file="$(find "${REPORTS_DIR}" -name '*compute-down*.md' | head -1)"
  if [ -n "$report_file" ]; then
    run grep -c "abc123def456" "$report_file"
    assert_output "0"
  fi
}

# UT-INFRA-184: --skip-backup with no reason text is refused before any stop.
@test "UT-INFRA-184: power.sh down --skip-backup with no reason is refused before any stop" {
  stub_use_rules aws "${TESTS_DIR}/fixtures/power-down-backup-ok.rules.sh"

  run "${INFRA_ROOT}/providers/aws/scripts/power.sh" dev down --skip-backup ""

  assert_failure
  refute_stub_called_with aws "stop-instances"
}

# UT-INFRA-195: a zero-byte object is never trusted as a backup (freshness
# bounce #1 fix) — refuses the stop even though the OK line itself parsed.
@test "UT-INFRA-195: power.sh down refuses the stop when the verified object is zero-byte" {
  stub_use_rules aws "${TESTS_DIR}/fixtures/power-down-backup-zerobyte.rules.sh"

  run "${INFRA_ROOT}/providers/aws/scripts/power.sh" dev down

  assert_failure
  assert_output --partial "zero-byte"
  refute_stub_called_with aws "stop-instances"
}

# UT-INFRA-196: a stale object (LastModified predates when the backup
# command was issued) is never trusted — refuses the stop.
@test "UT-INFRA-196: power.sh down refuses the stop when the verified object is stale" {
  stub_use_rules aws "${TESTS_DIR}/fixtures/power-down-backup-stale.rules.sh"

  run "${INFRA_ROOT}/providers/aws/scripts/power.sh" dev down

  assert_failure
  assert_output --partial "stale object"
  refute_stub_called_with aws "stop-instances"
}

# UT-INFRA-197: a sha256 mismatch between the OK line and the object's own
# metadata is never trusted — refuses the stop.
@test "UT-INFRA-197: power.sh down refuses the stop on a checksum mismatch" {
  stub_use_rules aws "${TESTS_DIR}/fixtures/power-down-backup-checksum-mismatch.rules.sh"

  run "${INFRA_ROOT}/providers/aws/scripts/power.sh" dev down

  assert_failure
  assert_output --partial "checksum mismatch"
  refute_stub_called_with aws "stop-instances"
}

# UT-INFRA-414 (CHANGED by AXI-1981, FR43) — power.sh down now acquires its
# OWN compute lock FIRST (acquire-then-check, same lock_acquire_exclusive
# helper deploy-prod.sh/power-data.sh use), not the old "no lock of its own,
# only check deploy/apply" shape. So this now DOES touch locks/compute.json
# — it is acquired, then released (RELEASED compute / delete-object) when
# deploy is found held, leaving nothing behind. Assertions updated to match
# (the exact message changed from "the deploy lock ... is held" to
# lock_acquire_exclusive's own "'deploy' is not free" / "releasing
# 'compute' and refusing"); still no head-object/stop-instances call is
# ever reached.
@test "UT-INFRA-414: power.sh down acquires then releases the compute lock when the deploy lock is held (FR43)" {
  stub_use_rules aws "${TESTS_DIR}/fixtures/power-down-backup-ok.rules.sh"
  export POWER_FIXTURE_DEPLOY_STATE=held

  run "${INFRA_ROOT}/providers/aws/scripts/power.sh" dev down

  assert_failure
  assert_output --partial "'deploy' is not free"
  assert_output --partial "releasing 'compute' and refusing"
  assert_output --partial "RELEASED compute"
  assert_stub_called aws "delete-object"
  refute_stub_called_with aws "head-object"
  refute_stub_called_with aws "stop-instances"
}

# UT-INFRA-593 (AXI-1981, FR43): new for this story — a deploy-lock check
# that cannot determine state at all (a transport error, not a clean
# "Not Found") is refused by lock_require_free exactly like a held lock
# (LOCK_RC_UNKNOWN is never treated as free, NFR2) — same release/refuse
# shape as UT-INFRA-414.
@test "UT-INFRA-593: power.sh down acquires then releases the compute lock when the deploy lock state is UNKNOWN (FR43)" {
  stub_use_rules aws "${TESTS_DIR}/fixtures/power-down-backup-ok.rules.sh"
  export POWER_FIXTURE_DEPLOY_STATE=unknown

  run "${INFRA_ROOT}/providers/aws/scripts/power.sh" dev down

  assert_failure
  assert_output --partial "'deploy' is not free"
  assert_output --partial "releasing 'compute' and refusing"
  assert_output --partial "RELEASED compute"
  assert_stub_called aws "delete-object"
  refute_stub_called_with aws "head-object"
  refute_stub_called_with aws "stop-instances"
}

# UT-INFRA-415 (CHANGED by AXI-1981, FR43): same, for the apply lock.
@test "UT-INFRA-415: power.sh down acquires then releases the compute lock when the apply lock is held (FR43)" {
  stub_use_rules aws "${TESTS_DIR}/fixtures/power-down-backup-ok.rules.sh"
  export POWER_FIXTURE_APPLY_STATE=held

  run "${INFRA_ROOT}/providers/aws/scripts/power.sh" dev down

  assert_failure
  assert_output --partial "'apply' is not free"
  assert_output --partial "releasing 'compute' and refusing"
  assert_output --partial "RELEASED compute"
  assert_stub_called aws "delete-object"
  refute_stub_called_with aws "head-object"
  refute_stub_called_with aws "stop-instances"
}

# UT-INFRA-640 (AXI-1981, FR43): new for this story — the compute lock is
# released and the process exits non-zero when TERM is delivered WHILE a
# stubbed aws call (the SSM backup send-command, the first genuinely
# in-flight call after compute is acquired) is actually in progress.
# Signalled on a STUB-LOG MARKER (the send-command argv actually being
# logged), never a bare sleep race — same deterministic pattern as
# tests/asset-sync.bats's UT-INFRA-585 and tests/lock_cleanup.bats's
# UT-INFRA-536.
@test "UT-INFRA-640: power.sh down releases the compute lock and exits non-zero when TERM arrives mid-backup (stub-log-marker timing)" {
  stub_use_rules aws "${TESTS_DIR}/fixtures/power-down-slow-ssm.rules.sh"

  setsid "${INFRA_ROOT}/providers/aws/scripts/power.sh" dev down &
  local pid=$!
  local tries=0
  while ! grep -qx "send-command" "$STUB_LOG" 2>/dev/null; do
    tries=$((tries + 1))
    if [ "$tries" -gt 1000 ]; then
      kill -TERM -- "-$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      fail "the slow send-command call was never reached — cannot exercise the in-flight abort path"
    fi
    sleep 0.005
  done
  kill -TERM -- "-$pid" 2>/dev/null || true
  local rc=0
  wait "$pid" || rc=$?

  [ "$rc" -ne 0 ]
  run grep -c "^delete-object$" "$STUB_LOG"
  [ "$output" -ge 1 ]
}
