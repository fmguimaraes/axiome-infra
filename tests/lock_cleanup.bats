#!/usr/bin/env bats
# tests/lock_cleanup.bats — scripts/lock.sh's lock-body read temp file
# (AXI-1973, FR63/AC58): removed on a signalled read, and the cleanup trap
# composes with lock_install_exit_trap. UT-INFRA-536..537.

load 'helpers/setup'

setup() {
  stub_setup
  export REPORT_REPO_ROOT="${INFRA_ROOT}"
  export REPORTS_DIR="${BATS_TEST_TMPDIR}/reports"
}

# UT-INFRA-536 — a SIGNALLED (TERM) lock read leaves no temp file behind.
# Uses a dedicated TMPDIR so the bare-filename mktemp result (no suffix,
# unpredictable name) can be verified by "the directory is empty after",
# not by guessing the generated name. setsid + whole-process-group signal,
# same pattern as tests/asset-sync.bats UT-INFRA-439.
#
# Review bounce #2: the original version polled for ANY file appearing in
# $tmpdir and signalled the instant one did. That signalling point sits
# BEFORE axiome_create_tracked_tempfile's registration step is guaranteed
# to have run relative to the file's own existence on disk from the test's
# point of view (polling sees "a file exists", not "a file is tracked") —
# exactly the ambiguity that let the pre-fix create-then-register ordering
# slip through here undetected. Signal instead on the `aws` stub actually
# being entered (polling $STUB_LOG for its `### CALL: aws` line, which
# tests/stubs/_common.sh's stub_main writes BEFORE stub_respond's `sleep 5`
# runs — see lock-signal-slow.rules.sh) — this lands the TERM deterministically
# mid-read, well after the tmpfile is both created AND registered, which is
# what "signalled during the read" means and is unambiguous about which
# phase of _lock_fetch is interrupted. The create/register-ordering window
# itself is covered directly (and signal-timing-exactly) by
# tests/cleanup_lib.bats UT-INFRA-624/625.
@test "UT-INFRA-536: scripts/lock.sh's lock-body read temp file is removed when the read is signalled (TERM) during the read" {
  stub_use_rules aws "${TESTS_DIR}/fixtures/lock-signal-slow.rules.sh"
  local tmpdir="${BATS_TEST_TMPDIR}/tmp"
  mkdir -p "$tmpdir"
  export TMPDIR="$tmpdir"

  setsid bash -c "source '${INFRA_ROOT}/scripts/lock.sh'; lock_status dev deploy" &
  local pid=$!
  local tries=0
  while ! grep -qx "### CALL: aws" "$STUB_LOG" 2>/dev/null; do
    tries=$((tries + 1))
    if [ "$tries" -gt 1000 ]; then
      kill -TERM -- "-$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      fail "aws stub was never reached — cannot exercise the signal-during-the-read path"
    fi
    sleep 0.005
  done
  kill -TERM -- "-$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true

  run find "$tmpdir" -mindepth 1
  assert_output ""
}

# UT-INFRA-537 — the tmp-file cleanup trap installed inside _lock_fetch
# composes with lock_install_exit_trap's own release trap: a normal
# (non-signalled) exit from a process that did both still releases the
# marked lock AND leaves no lock-read temp file behind.
@test "UT-INFRA-537: lock.sh's tmp-file cleanup trap composes with lock_install_exit_trap (both the release and the cleanup run)" {
  stub_use_rules aws "${TESTS_DIR}/fixtures/lock-cleanup-compose.rules.sh"
  local tmpdir="${BATS_TEST_TMPDIR}/tmp"
  mkdir -p "$tmpdir"
  export TMPDIR="$tmpdir"

  run bash -c "
    source '${INFRA_ROOT}/scripts/lock.sh'
    lock_mark_for_auto_release dev deploy 'fixed-token-537'
    lock_install_exit_trap
    lock_status dev deploy >/dev/null 2>&1 || true
  "
  assert_success
  assert_stub_called aws "delete-object"
  run find "$tmpdir" -mindepth 1
  assert_output ""
}
