#!/usr/bin/env bats
# tests/report_secret_and_cleanup.bats — scripts/lib/report.sh's public
# report_is_secret_value (FR63) and no-leftover-temp-file contract (AC58).
# UT-INFRA-530..535, UT-INFRA-504..507 (AXI-1968: the tag=/sha256:/
# image@sha256:/commit= delimited-hex-exemption fix).

load 'helpers/setup'

setup() {
  stub_setup
  stub_use_rules aws "${TESTS_DIR}/fixtures/sts-actor.rules.sh"
  REPORTS_DIR="${BATS_TEST_TMPDIR}/reports"
  export REPORTS_DIR
  REPORT_REPO_ROOT="${BATS_TEST_TMPDIR}"
  export REPORT_REPO_ROOT
  # shellcheck disable=SC1091
  source "${INFRA_ROOT}/scripts/lib/report.sh"
}

# UT-INFRA-530 — FR63 rework (review bounce #1): report_is_secret_value has
# TWO independent branches. The WHOLE-KEY-NAME branch refuses a sensitive
# key (password/secret/token/... or a *_password/*_secret/*_token/... key)
# paired with a value that is not itself an allowlisted placeholder — it is
# never a trailing-substring match against the whole line, so a key that
# merely CONTAINS a sensitive-sounding word as part of a longer, different
# key (password_policy, token_ttl) is never refused regardless of value.
@test "UT-INFRA-530: report_is_secret_value allows an innocuous key name or an allowlisted placeholder value" {
  run report_is_secret_value "password_policy=strict"
  assert_failure
  run report_is_secret_value "token_ttl=3600"
  assert_failure
  run report_is_secret_value "override_token=none"
  assert_failure
  run report_is_secret_value "password=<redacted>"
  assert_failure
  run report_is_secret_value "password=****"
  assert_failure
}

# UT-INFRA-544 — the companion refusals: a sensitive key (matched WHOLE,
# never as a substring) paired with a real-looking value is refused however
# the pair is spelled — key=value, --flag value, --flag=value, a JSON
# "key": "value" pair, a key preceded by other words, or spaces around '='.
@test "UT-INFRA-544: report_is_secret_value refuses a sensitive key paired with a real-looking value" {
  run report_is_secret_value "PGPASSWORD=hunter2hunter2"
  assert_success
  run report_is_secret_value "--password hunter2hunter2"
  assert_success
  run report_is_secret_value "--password=hunter2hunter2"
  assert_success
  run report_is_secret_value "MONGO_ROOT_PASSWORD=abc"
  assert_success
  run report_is_secret_value "override_token=abc123def456"
  assert_success
  run report_is_secret_value "my password=hunter2"
  assert_success
  run report_is_secret_value "Password = hunter2"
  assert_success
  run report_is_secret_value '"password": "hunter2"'
  assert_success
  run report_is_secret_value "please rotate this: token=abc123def456 before you deploy"
  assert_success
}

# UT-INFRA-564 (AXI-1972, follow-up g): YAML-style "password: value" with
# an UNQUOTED key (the pre-existing JSON branch only fired for a quoted
# key) is refused, the same as "password=value".
@test "UT-INFRA-564: report_is_secret_value refuses an unquoted YAML-style 'password: value'" {
  run report_is_secret_value "password: hunter2hunter2"
  assert_success
  run report_is_secret_value "token: abc123def456"
  assert_success
}

# UT-INFRA-565 (AXI-1972, follow-up g): ordinary report prose using a
# colon is never refused by the new YAML branch — only a WHOLE sensitive
# key, paired with a non-allowlisted value, is.
@test "UT-INFRA-565: report_is_secret_value does not refuse ordinary 'key: value' report lines" {
  run report_is_secret_value "Status: ok"
  assert_failure
  run report_is_secret_value "token_ttl: 3600"
  assert_failure
  run report_is_secret_value "Password policy: strict"
  assert_failure
}

# UT-INFRA-531 — FR63: a value that LOOKS like a credential is refused
# whatever key/flag it is attached to — including a key with no
# sensitive-sounding name at all.
@test "UT-INFRA-531: report_is_secret_value refuses a credential-shaped value regardless of its key name" {
  run report_is_secret_value "custom_field=AKIAIOSFODNN7EXAMPLE"
  assert_success
  run report_is_secret_value "note=postgres://user:supersecret@db.internal:5432/app"
  assert_success
  run report_is_secret_value "anything=eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U"
  assert_success
  run report_is_secret_value "whatever: Bearer abcdefghijklmnopqrstuvwxyz0123456789"
  assert_success
}

# UT-INFRA-532 — FR63 follow-up: the pure-hex exemption is restricted to the
# two recognised hash-digest lengths (40 = git SHA-1, 64 = SHA-256); any
# OTHER all-hex length of 40+ chars is refused, closing the "would allow an
# all-hex secret" gap.
@test "UT-INFRA-532: the hex exemption only covers git-SHA and sha256 lengths, not every hex run" {
  run report_is_secret_value "deployed commit 1234567890abcdef1234567890abcdef12345678"
  assert_failure
  run report_is_secret_value "image digest sha256:deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
  assert_failure
  # 48 pure hex chars, space-separated so the match isolates exactly the
  # hex run (not a recognised digest length) — refused.
  run report_is_secret_value "leaked a1b2c3a1b2c3a1b2c3a1b2c3a1b2c3a1b2c3a1b2c3a1b2c3"
  assert_success
  # 44 pure hex chars (also not a recognised digest length) — refused.
  run report_is_secret_value "value a1b2c3a1b2c3a1b2c3a1b2c3a1b2c3a1b2c3a1b2c3ab"
  assert_success
}

# UT-INFRA-504 — AXI-1968: the generic-secret scan's OWN base64 alphabet
# (`[A-Za-z0-9/+=]`) includes `=` and `/` — the exact operator characters a
# routine `tag=<sha>` / `image@sha256:<digest>` audit line uses right next
# to the hash. Before this fix, that let the scan swallow a non-hex prefix
# like `tag=` INTO the same contiguous match (since `t`/`a`/`g`/`=` are all
# members of the broader alphabet too), so the combined string was no
# longer pure hex and the git-SHA/sha256 exemption above never applied —
# refusing a perfectly legitimate `tag=<40-hex-sha>` line outright. These
# four cases are the exact shapes that trap required to not be refused;
# UT-INFRA-532 above already proves the exemption still does NOT widen to
# any other length or an undelimited run.
@test "UT-INFRA-504: report_is_secret_value allows a git SHA / sha256 digest written as tag=, sha256:, image@sha256: or commit=" {
  local hex40 hex64
  hex40="$(printf 'a%.0s' $(seq 1 40))"
  hex64="$(printf 'a%.0s' $(seq 1 64))"
  run report_is_secret_value "tag=${hex40}"
  assert_failure
  run report_is_secret_value "sha256:${hex64}"
  assert_failure
  run report_is_secret_value "image@sha256:${hex64}"
  assert_failure
  run report_is_secret_value "commit=${hex40}"
  assert_failure
}

# UT-INFRA-505 — the delimited exemption never widens to a hex run that is
# NOT exactly 40 or 64 chars, even when it sits right next to one of the
# newly-recognised delimiters ('=' here) — a 41-char run is refused exactly
# as a bare one would be (mutation check against UT-INFRA-504/532 both
# narrowing and widening in the wrong direction).
@test "UT-INFRA-505: report_is_secret_value still refuses a delimited hex run of the WRONG length" {
  local hex41 hex65
  hex41="$(printf 'a%.0s' $(seq 1 41))"
  hex65="$(printf 'a%.0s' $(seq 1 65))"
  run report_is_secret_value "tag=${hex41}"
  assert_success
  run report_is_secret_value "tag=${hex65}"
  assert_success
}

# UT-INFRA-506 — a hex run merely ADJACENT to (not delimited from) other
# base64-alphabet text — a letter, digit, '+', '_', '.', or '-' touching
# either end — is still refused: that run is a substring of something
# LONGER, not a standalone git SHA/digest, and must still reach the generic
# scan unexempted.
@test "UT-INFRA-506: report_is_secret_value refuses a 40/64-hex run glued to other base64-alphabet text" {
  local hex40
  hex40="$(printf 'a%.0s' $(seq 1 40))"
  run report_is_secret_value "mytag${hex40}done"
  assert_success
  run report_is_secret_value "x${hex40}"
  assert_success
  run report_is_secret_value "${hex40}x"
  assert_success
}

# UT-INFRA-507 — the delimited-hex exemption is judged on VALUE SHAPE only,
# same as every other branch of report_is_secret_value: a SENSITIVE key
# (e.g. `password=`) paired with a 40-char hex value is still refused by
# the separate sensitive-key-pair branch — the new exemption never
# overrides that check.
@test "UT-INFRA-507: report_is_secret_value still refuses password=<40-hex> despite the new delimited exemption" {
  local hex40
  hex40="$(printf 'a%.0s' $(seq 1 40))"
  run report_is_secret_value "password=${hex40}"
  assert_success
}

# UT-INFRA-533 — AC58: an ABANDONED report sequence (report_init runs,
# report_finish never does, because the process just exits) leaves no
# temp file behind.
@test "UT-INFRA-533: an abandoned report sequence leaves no temp buffer behind" {
  local buf_file="${BATS_TEST_TMPDIR}/buf_path.txt"
  run bash -c "
    source '${INFRA_ROOT}/scripts/lib/report.sh'
    report_init dev abandoned-test
    printf '%s' \"\$_REPORT_BUF\" > '${buf_file}'
  "
  assert_success
  local buf
  buf="$(cat "$buf_file")"
  [ -n "$buf" ]
  [ ! -e "$buf" ]
}

# UT-INFRA-534 — AC58: a report sequence that is SIGNALLED (TERM) mid-run
# also leaves no temp buffer behind. setsid + whole-process-group signal
# (see tests/asset-sync.bats UT-INFRA-439) — a bare `kill -TERM $pid` would
# only reach the top process, not necessarily where the buffer already
# exists by the time we signal.
@test "UT-INFRA-534: a signalled (TERM) report sequence leaves no temp buffer behind" {
  local buf_file="${BATS_TEST_TMPDIR}/buf_path.txt"
  local script="${BATS_TEST_TMPDIR}/sig.sh"
  cat > "$script" <<EOF
#!/usr/bin/env bash
set -euo pipefail
source "${INFRA_ROOT}/scripts/lib/report.sh"
report_init dev sig-test
printf '%s' "\${_REPORT_BUF}" > "${buf_file}"
sleep 5
EOF
  chmod +x "$script"

  setsid "$script" &
  local pid=$!
  local tries=0
  while [ ! -s "$buf_file" ]; do
    tries=$((tries + 1))
    if [ "$tries" -gt 1000 ]; then
      kill -TERM -- "-$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      fail "buffer path never appeared — cannot exercise the signal path"
    fi
    sleep 0.005
  done
  kill -TERM -- "-$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true

  local buf
  buf="$(cat "$buf_file")"
  [ -n "$buf" ]
  [ ! -e "$buf" ]
}

# UT-INFRA-535 — AC58: the cleanup trap COMPOSES with a caller's own
# pre-existing EXIT trap — both run, and the script's own exit status is
# preserved (never overwritten by the library's cleanup).
@test "UT-INFRA-535: report.sh's cleanup trap composes with a pre-existing caller EXIT trap and preserves exit status" {
  local marker="${BATS_TEST_TMPDIR}/marker.txt"
  local buf_file="${BATS_TEST_TMPDIR}/buf_path2.txt"
  local script="${BATS_TEST_TMPDIR}/compose.sh"
  cat > "$script" <<EOF
#!/usr/bin/env bash
set -euo pipefail
trap 'echo caller-trap-ran >> "${marker}"' EXIT
source "${INFRA_ROOT}/scripts/lib/report.sh"
report_init dev compose-test
printf '%s' "\${_REPORT_BUF}" > "${buf_file}"
exit 7
EOF
  chmod +x "$script"

  run "$script"
  [ "$status" -eq 7 ]
  run cat "$marker"
  assert_output "caller-trap-ran"
  local buf
  buf="$(cat "$buf_file")"
  [ ! -e "$buf" ]
}

# UT-INFRA-622 (AXI-1973 rework, review bounce #1 follow-up): when
# lock_install_exit_trap runs BEFORE report_init (deploy-prod.sh's actual
# order — see scripts/deploy-prod.sh), the FINAL installed EXIT trap is
# lock.sh's own `_lock_exit_trap_handler`, which chains INTO
# cleanup.sh's `_axiome_cleanup_trap_exit` as the inner, saved command.
# The script's real exit status (1) must survive that chain intact — not
# regress to 0 because an intermediate command (axiome_run_cleanup)
# clobbered `$?` before the inner handler could read it.
@test "UT-INFRA-622: a real exit status survives lock.sh-then-report.sh EXIT trap chaining" {
  local script="${BATS_TEST_TMPDIR}/chain1.sh"
  cat > "$script" <<EOF
#!/usr/bin/env bash
set -uo pipefail
. "${INFRA_ROOT}/scripts/lock.sh"
lock_install_exit_trap
. "${INFRA_ROOT}/scripts/lib/report.sh"
report_init dev chain-test
exit 1
EOF
  chmod +x "$script"
  run "$script"
  [ "$status" -eq 1 ]
}

# UT-INFRA-623 — the reverse order: report_init runs BEFORE
# lock_install_exit_trap, so cleanup.sh's handler becomes the final
# installed trap and chains INTO lock.sh's `_lock_exit_trap_handler` as
# the inner, saved command. Same requirement, opposite direction.
@test "UT-INFRA-623: a real exit status survives report.sh-then-lock.sh EXIT trap chaining" {
  local script="${BATS_TEST_TMPDIR}/chain2.sh"
  cat > "$script" <<EOF
#!/usr/bin/env bash
set -uo pipefail
. "${INFRA_ROOT}/scripts/lib/report.sh"
report_init dev chain-test
. "${INFRA_ROOT}/scripts/lock.sh"
lock_install_exit_trap
exit 1
EOF
  chmod +x "$script"
  run "$script"
  [ "$status" -eq 1 ]
}
