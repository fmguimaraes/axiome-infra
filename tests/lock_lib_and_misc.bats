#!/usr/bin/env bats
# tests/lock_lib_and_misc.bats — scripts/lock.sh as a sourceable library
# (lock_require_free, the auto-release trio) plus CLI edge cases (AXI-1947).
# UT-INFRA-118..125, 393..400, 401..406.

load 'helpers/setup'

setup() {
  stub_setup
  export REPORT_REPO_ROOT="${INFRA_ROOT}"
}

# UT-INFRA-118: lock_require_free succeeds only when the lock is FREE.
@test "UT-INFRA-118: lock_require_free succeeds on a free lock, refuses on a held one" {
  stub_use_rules aws "${TESTS_DIR}/fixtures/lock-status.rules.sh"

  run bash -c "set -e; . '${INFRA_ROOT}/scripts/lock.sh'; lock_require_free dev data-tier && echo FREE_OK"
  assert_success
  assert_output --partial "FREE_OK"

  run bash -c ". '${INFRA_ROOT}/scripts/lock.sh'; lock_require_free dev deploy; echo \"rc=\$?\""
  assert_output --partial "rc=1"
}

# UT-INFRA-119: lock_require_free refuses on UNDETERMINED exactly like HELD
# (NFR2, fail-closed) — "could not check" must never look like "free".
@test "UT-INFRA-119: lock_require_free treats UNDETERMINED the same as HELD" {
  stub_use_rules aws "${TESTS_DIR}/fixtures/lock-status.rules.sh"

  run bash -c ". '${INFRA_ROOT}/scripts/lock.sh'; lock_require_free staging deploy; echo \"rc=\$?\""
  assert_output --partial "rc=2"
}

# UT-INFRA-120: lock_mark_for_auto_release REFUSES to register 'data-tier'
# (FR29 — no automatic release of the data-tier lock by any exit/signal
# route). No aws call happens at all — the refusal is before any I/O.
@test "UT-INFRA-120: lock_mark_for_auto_release refuses the data-tier lock" {
  run bash -c ". '${INFRA_ROOT}/scripts/lock.sh'; lock_mark_for_auto_release dev data-tier tok123; echo \"rc=\$?\""

  assert_output --partial "refuses 'data-tier'"
  assert_output --partial "rc=3"
  run grep -c "### CALL: aws" "$STUB_LOG"
  assert_output "0"
}

# UT-INFRA-121: lock_release_held releases a 'deploy' lock marked for
# auto-release, and a SECOND call is a no-op (idempotent — the registry is
# cleared after the first release, so there is never a second delete).
@test "UT-INFRA-121: lock_release_held releases a marked lock and is idempotent" {
  stub_use_rules aws "${TESTS_DIR}/fixtures/lock-release.rules.sh"

  run bash -c ". '${INFRA_ROOT}/scripts/lock.sh'; lock_mark_for_auto_release dev deploy mytoken; lock_release_held; echo \"first_rc=\$?\"; lock_release_held; echo \"second_rc=\$?\""

  assert_success
  assert_output --partial "RELEASED deploy"
  assert_output --partial "first_rc=0"
  assert_output --partial "second_rc=0"
  run grep -cx "delete-object" "$STUB_LOG"
  assert_output "1"
}

# UT-INFRA-393 (B3): _lock_require_jq RETURNS (never exits) when jq is
# missing — a sourced caller must survive past the call, not have its shell
# killed out from under it. PATH is rebuilt from scratch (symlinks to the
# real coreutils this file needs) so jq is genuinely absent everywhere,
# never shadowed by a shell function.
@test "UT-INFRA-393: _lock_require_jq returns nonzero without exiting the sourcing shell when jq is missing" {
  local fakebin="${BATS_TEST_TMPDIR}/nojq-bin" t
  mkdir -p "$fakebin"
  for t in bash date mktemp rm cat sed printf grep env sh dirname; do
    command -v "$t" >/dev/null 2>&1 && ln -sf "$(command -v "$t")" "${fakebin}/${t}"
  done

  run env -i PATH="$fakebin" bash -c ". '${INFRA_ROOT}/scripts/lock.sh'; _lock_require_jq; echo \"rc=\$?\"; echo STILL_ALIVE"

  assert_output --partial "rc=1"
  assert_output --partial "STILL_ALIVE"
}

# UT-INFRA-394 (B4): sourcing lock.sh and calling its public read functions
# must never clobber a caller's own PROJECT/REGION/ENV/NAME/TOKEN globals —
# lock_env_defaults sets only `_LOCK_`-prefixed variables.
@test "UT-INFRA-394: lock.sh never clobbers a caller's PROJECT/REGION/ENV/NAME/TOKEN" {
  stub_use_rules aws "${TESTS_DIR}/fixtures/lock-status.rules.sh"

  run bash -c "
    PROJECT=caller-project; REGION=caller-region; ENV=caller-env; NAME=caller-name; TOKEN=caller-token
    . '${INFRA_ROOT}/scripts/lock.sh'
    lock_status dev deploy >/dev/null
    lock_require_free dev data-tier >/dev/null
    echo \"PROJECT=\${PROJECT} REGION=\${REGION} ENV=\${ENV} NAME=\${NAME} TOKEN=\${TOKEN}\"
  "

  assert_output --partial "PROJECT=caller-project REGION=caller-region ENV=caller-env NAME=caller-name TOKEN=caller-token"
}

# UT-INFRA-395 (B5): lock_install_exit_trap CHAINS onto a pre-existing EXIT
# trap instead of overwriting it — the caller's own cleanup still runs.
@test "UT-INFRA-395: lock_install_exit_trap chains onto a pre-existing EXIT trap" {
  stub_use_rules aws "${TESTS_DIR}/fixtures/lock-release.rules.sh"

  run bash -c ". '${INFRA_ROOT}/scripts/lock.sh'; trap 'echo PRE_EXISTING_TRAP_RAN' EXIT; lock_mark_for_auto_release dev deploy mytoken; lock_install_exit_trap; echo done"

  assert_success
  assert_output --partial "done"
  assert_output --partial "RELEASED deploy"
  assert_output --partial "PRE_EXISTING_TRAP_RAN"
}

# UT-INFRA-396 (B5): a normal (success) exit releases the marked lock via
# the chained trap.
@test "UT-INFRA-396: lock_install_exit_trap releases the lock on a normal exit" {
  stub_use_rules aws "${TESTS_DIR}/fixtures/lock-release.rules.sh"

  run bash -c ". '${INFRA_ROOT}/scripts/lock.sh'; lock_mark_for_auto_release dev deploy mytoken; lock_install_exit_trap; echo done"

  assert_success
  assert_output --partial "done"
  assert_output --partial "RELEASED deploy"
}

# UT-INFRA-397 (B5): an ERROR exit (nonzero `exit`) still runs the chained
# trap and releases the lock — release does not depend on a clean exit.
@test "UT-INFRA-397: lock_install_exit_trap releases the lock on an error exit" {
  stub_use_rules aws "${TESTS_DIR}/fixtures/lock-release.rules.sh"

  run bash -c ". '${INFRA_ROOT}/scripts/lock.sh'; lock_mark_for_auto_release dev deploy mytoken; lock_install_exit_trap; exit 1"

  assert_failure
  [ "$status" -eq 1 ]
  assert_output --partial "RELEASED deploy"
}

# UT-INFRA-398 (B5): SIGTERM is routed through `exit`, so it still runs the
# chained EXIT trap instead of leaking the lock (a bare EXIT trap is never
# fired by a signal unless the shell actually calls exit).
@test "UT-INFRA-398: lock_install_exit_trap releases the lock on SIGTERM" {
  stub_use_rules aws "${TESTS_DIR}/fixtures/lock-release.rules.sh"

  run bash -c ". '${INFRA_ROOT}/scripts/lock.sh'; lock_mark_for_auto_release dev deploy mytoken; lock_install_exit_trap; kill -TERM \$\$; sleep 5; echo SHOULD_NOT_REACH"

  assert_output --partial "RELEASED deploy"
  refute_output --partial "SHOULD_NOT_REACH"
}

# UT-INFRA-399 (B5): data-tier can never be auto-released by any route —
# it was refused at mark time, so install_exit_trap + a normal exit makes
# NO aws call for it at all (lock_release_held's registry never has it).
@test "UT-INFRA-399: data-tier is never auto-released via lock_install_exit_trap" {
  run bash -c ". '${INFRA_ROOT}/scripts/lock.sh'; lock_mark_for_auto_release dev data-tier mytoken >/dev/null 2>&1; lock_install_exit_trap; echo done"

  assert_output --partial "done"
  run grep -c "### CALL: aws" "$STUB_LOG"
  assert_output "0"
}

# UT-INFRA-400 (B5): lock_release_held is safe to call with nothing
# registered — a no-op, rc 0, no aws call.
@test "UT-INFRA-400: lock_release_held with nothing registered is a no-op" {
  run bash -c ". '${INFRA_ROOT}/scripts/lock.sh'; lock_release_held; echo \"rc=\$?\""

  assert_output --partial "rc=0"
  run grep -c "### CALL: aws" "$STUB_LOG"
  assert_output "0"
}

# UT-INFRA-122: sourcing lock.sh has NO side effects — it makes no aws call
# even though AWS_STUB_RULES is left unconfigured (any call would fail).
@test "UT-INFRA-122: sourcing lock.sh makes no aws call and defines its functions" {
  run bash -c "set -e; . '${INFRA_ROOT}/scripts/lock.sh'; declare -f lock_acquire >/dev/null && declare -f lock_release >/dev/null && declare -f lock_status >/dev/null && declare -f lock_override >/dev/null && echo SOURCED_OK"

  assert_success
  assert_output --partial "SOURCED_OK"
  run grep -c "### CALL: aws" "$STUB_LOG"
  assert_output "0"
}

# UT-INFRA-123: running lock.sh with no arguments prints usage and exits
# non-zero, without touching aws.
@test "UT-INFRA-123: lock.sh with no arguments prints usage and makes no aws call" {
  run "${INFRA_ROOT}/scripts/lock.sh"

  assert_failure
  run grep -c "### CALL: aws" "$STUB_LOG"
  assert_output "0"
}

# UT-INFRA-124: an unknown environment is refused before any aws call
# (acquire and status both go through the same lock_env_defaults guard).
@test "UT-INFRA-124: lock.sh refuses an unknown environment before any aws call" {
  run "${INFRA_ROOT}/scripts/lock.sh" qa status deploy

  assert_failure
  assert_output --partial "unknown environment"
  run grep -c "### CALL: aws" "$STUB_LOG"
  assert_output "0"
}

# UT-INFRA-125: an unknown lock name on status is refused before any aws
# call.
@test "UT-INFRA-125: lock.sh status refuses an unknown lock name before any aws call" {
  run "${INFRA_ROOT}/scripts/lock.sh" dev status bogus

  assert_failure
  assert_output --partial "unknown lock name"
  run grep -c "### CALL: aws" "$STUB_LOG"
  assert_output "0"
}

# UT-INFRA-401 (bounce #2): a pre-existing EXIT trap whose command contains
# a SINGLE QUOTE must still both run in full AND still see the lock
# released — this is the exact shape that broke the old sed-based
# `trap -p` reconstruction (unexpected EOF). The trap text itself
# (`echo "it's fine"`) is valid shell on its own.
@test "UT-INFRA-401: lock_install_exit_trap survives a caller trap containing a single quote" {
  stub_use_rules aws "${TESTS_DIR}/fixtures/lock-release.rules.sh"
  local script="${BATS_TEST_TMPDIR}/trap_quote.sh"
  cat > "$script" <<'EOF'
#!/usr/bin/env bash
trap 'echo "it'\''s fine"' EXIT
EOF
  cat >> "$script" <<EOF
. '${INFRA_ROOT}/scripts/lock.sh'
lock_mark_for_auto_release dev deploy mytoken
lock_install_exit_trap
echo done
EOF
  run bash "$script"

  assert_success
  assert_output --partial "done"
  assert_output --partial "RELEASED deploy"
  assert_output --partial "it's fine"
}

# UT-INFRA-402 (bounce #2): a pre-existing EXIT trap containing DOUBLE
# QUOTES plus a `$VAR` reference must still expand that variable at FIRE
# time (deferred expansion, same as if the trap had never been wrapped)
# and must still run alongside the release.
@test "UT-INFRA-402: lock_install_exit_trap survives a caller trap with double quotes and a \$VAR" {
  stub_use_rules aws "${TESTS_DIR}/fixtures/lock-release.rules.sh"
  local script="${BATS_TEST_TMPDIR}/trap_var.sh"
  cat > "$script" <<EOF
#!/usr/bin/env bash
. '${INFRA_ROOT}/scripts/lock.sh'
FOO=hello
trap 'echo "value=\$FOO"' EXIT
lock_mark_for_auto_release dev deploy mytoken
lock_install_exit_trap
echo done
EOF
  run bash "$script"

  assert_success
  assert_output --partial "done"
  assert_output --partial "RELEASED deploy"
  assert_output --partial "value=hello"
}

# UT-INFRA-403 (bounce #2): a pre-existing EXIT trap spanning a NEWLINE
# (multiple commands in one trap string) must run every line and still
# release the lock.
@test "UT-INFRA-403: lock_install_exit_trap survives a caller trap with a newline / multiple commands" {
  stub_use_rules aws "${TESTS_DIR}/fixtures/lock-release.rules.sh"
  local script="${BATS_TEST_TMPDIR}/trap_newline.sh"
  cat > "$script" <<'EOF'
#!/usr/bin/env bash
trap 'echo line1
echo line2' EXIT
EOF
  cat >> "$script" <<EOF
. '${INFRA_ROOT}/scripts/lock.sh'
lock_mark_for_auto_release dev deploy mytoken
lock_install_exit_trap
echo done
EOF
  run bash "$script"

  assert_success
  assert_output --partial "done"
  assert_output --partial "RELEASED deploy"
  assert_output --partial "line1"
  assert_output --partial "line2"
}

# UT-INFRA-404 (bounce #2): a pre-existing EXIT trap containing a
# BACKSLASH must still run byte-for-byte and still release the lock.
@test "UT-INFRA-404: lock_install_exit_trap survives a caller trap with a backslash" {
  stub_use_rules aws "${TESTS_DIR}/fixtures/lock-release.rules.sh"
  local script="${BATS_TEST_TMPDIR}/trap_backslash.sh"
  cat > "$script" <<'EOF'
#!/usr/bin/env bash
trap 'echo "back\\slash"' EXIT
EOF
  cat >> "$script" <<EOF
. '${INFRA_ROOT}/scripts/lock.sh'
lock_mark_for_auto_release dev deploy mytoken
lock_install_exit_trap
echo done
EOF
  run bash "$script"

  assert_success
  assert_output --partial "done"
  assert_output --partial "RELEASED deploy"
  assert_output --partial 'back\slash'
}

# UT-INFRA-405 (bounce #2): the ORIGINAL exit status is preserved end to
# end — a script that calls `exit 7` after installing the trap still
# exits 7, even though the handler runs lock_release_held and the
# (no-op, here) restored trap in between.
@test "UT-INFRA-405: lock_install_exit_trap preserves the original exit status" {
  stub_use_rules aws "${TESTS_DIR}/fixtures/lock-release.rules.sh"

  run bash -c ". '${INFRA_ROOT}/scripts/lock.sh'; lock_mark_for_auto_release dev deploy mytoken; lock_install_exit_trap; exit 7"

  [ "$status" -eq 7 ]
  assert_output --partial "RELEASED deploy"
}

# UT-INFRA-406 (bounce #2): calling lock_install_exit_trap TWICE must not
# chain the handler to itself — exactly ONE delete-object call, not two.
@test "UT-INFRA-406: lock_install_exit_trap called twice does not self-chain or double-release" {
  stub_use_rules aws "${TESTS_DIR}/fixtures/lock-release.rules.sh"

  run bash -c ". '${INFRA_ROOT}/scripts/lock.sh'; lock_mark_for_auto_release dev deploy mytoken; lock_install_exit_trap; lock_install_exit_trap; echo done"

  assert_success
  assert_output --partial "done"
  assert_output --partial "RELEASED deploy"
  run grep -cx "delete-object" "$STUB_LOG"
  assert_output "1"
}
