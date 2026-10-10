#!/usr/bin/env bats
# tests/cleanup_lib.bats — scripts/lib/cleanup.sh's registry primitives in
# isolation (AXI-1973, AC58). UT-INFRA-541..542.

load 'helpers/setup'

setup() {
  stub_setup
  # shellcheck disable=SC1091
  source "${INFRA_ROOT}/scripts/lib/cleanup.sh"
}

# UT-INFRA-541 — axiome_run_cleanup never removes a registered DIRECTORY,
# and never acts on an empty-string entry: it only ever removes a path
# that both (a) is a non-empty string and (b) resolves to a PLAIN FILE.
@test "UT-INFRA-541: axiome_run_cleanup never removes a directory or an empty registration" {
  local dir="${BATS_TEST_TMPDIR}/a-real-directory"
  mkdir -p "$dir"
  local file="${BATS_TEST_TMPDIR}/a-real-file"
  : > "$file"

  axiome_register_cleanup "$dir"
  axiome_register_cleanup ""
  axiome_register_cleanup "$file"
  axiome_run_cleanup

  [ -d "$dir" ]
  [ ! -e "$file" ]
}

# UT-INFRA-542 — axiome_unregister_cleanup is a safe no-op: unregistering a
# path that was never registered (or an empty string) does not error and
# does not disturb the paths that WERE registered.
@test "UT-INFRA-542: axiome_unregister_cleanup is a no-op for an unregistered or empty path" {
  local kept="${BATS_TEST_TMPDIR}/kept-file"
  : > "$kept"
  axiome_register_cleanup "$kept"

  axiome_unregister_cleanup "${BATS_TEST_TMPDIR}/never-registered"
  axiome_unregister_cleanup ""

  axiome_run_cleanup
  [ ! -e "$kept" ]
}

# UT-INFRA-624 (AXI-1973, review bounce #2): axiome_create_tracked_tempfile
# registers in the CALLER'S shell, never a lost subshell. Proof: calling
# it directly (not via command substitution) leaves the path present in
# `_AXIOME_CLEANUP_PATHS` immediately — if the implementation instead
# returned the path via `outvar="$(axiome_create_tracked_tempfile ...)"`,
# the `axiome_register_cleanup` call inside that substitution would run
# in a forked subshell and this assertion would see an EMPTY registry
# (the array mutation never reaching the parent shell) even though the
# file itself still exists on disk.
@test "UT-INFRA-624: axiome_create_tracked_tempfile registers in the caller's shell, not a lost subshell" {
  local path=""
  axiome_create_tracked_tempfile path "${BATS_TEST_TMPDIR}"
  [ -n "$path" ]
  [ -f "$path" ]

  local found=0 p
  for p in "${_AXIOME_CLEANUP_PATHS[@]}"; do
    [ "$p" = "$path" ] && found=1
  done
  [ "$found" -eq 1 ]

  axiome_run_cleanup
  [ ! -e "$path" ]
}

# UT-INFRA-625 (AXI-1973, review bounce #2): closes the real TERM-signal
# race the reviewer found in _lock_fetch — a bare `tmpfile="$(mktemp)"`
# THEN `axiome_register_cleanup`/`axiome_install_cleanup_trap` leaves a
# real (if narrow) window where a signal lands after the file exists but
# before anything tracks it. axiome_create_tracked_tempfile closes this
# by construction (trap installed and path registered BEFORE the file is
# created, in strict sequence — there is no concurrency inside one shell,
# so once that ordering is fixed the window cannot reopen).
#
# A fully deterministic unit test of the window itself is not achievable
# without touching production code: the helper uses no external command
# (no aws, no mktemp(1) binary — just `:` redirection, `umask`, `set -C`)
# to intercept via a PATH stub or FIFO, and signalling "as soon as the
# function is entered" races real OS scheduling the same way production
# does. So, per the fallback asked for: this test runs BOTH the OLD
# (pre-fix) create-then-register shape — reproduced verbatim as a local
# comparison function, deliberately widening its real gap with a short
# sleep so a scheduler-level race becomes empirically observable in a
# bounded test, exactly the "under load that window is wide enough to
# hit" scenario the bounce describes — and the NEW helper, 200 iterations
# each, signalling the whole process group at a randomised sub-sleep
# offset per iteration, and counts leaked files for each. The old shape's
# own real gap is widened to 30ms (modelling "under load") purely so a
# single-digit-millisecond jitter reliably lands inside it without
# needing a wide (and slow) delay range — the fix's correctness does not
# depend on the delay/gap ratio (see the helper's own ordering guarantee),
# only the OLD shape's demonstration does. Bounded well under 20s: 200
# iterations x 2 shapes x ~5ms average jitter is low single-digit seconds
# of sleep, plus per-iteration process/fork overhead.
@test "UT-INFRA-625: the create-then-register race is closed (200-iteration old-vs-new loop)" {
  local dir="${BATS_TEST_TMPDIR}/race"
  mkdir -p "$dir"
  local helper_src="${INFRA_ROOT}/scripts/lib/cleanup.sh"

  local old_leaks=0 new_leaks=0 i delay pid
  for i in $(seq 1 200); do
    delay="0.00$(( (RANDOM % 9) + 1 ))"  # 0.001 .. 0.009s jitter

    # OLD shape: mktemp first, trap/register only after a deliberately
    # widened gap (modelling "under load") — must leak at least once.
    rm -f "${dir}"/old.* 2>/dev/null || true
    setsid bash -c "
      source '${helper_src}'
      tmpfile=\"\$(mktemp '${dir}/old.XXXXXX')\"
      sleep 0.03
      axiome_install_cleanup_trap
      axiome_register_cleanup \"\${tmpfile}\"
      sleep 1
    " &
    pid=$!
    sleep "$delay"
    kill -TERM -- "-${pid}" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    [ -n "$(find "${dir}" -maxdepth 1 -name 'old.*' 2>/dev/null)" ] && old_leaks=$((old_leaks + 1))
    rm -f "${dir}"/old.* 2>/dev/null || true

    # NEW shape: axiome_create_tracked_tempfile — register-before-create,
    # same jitter, same signal — must never leak.
    rm -f "${dir}"/.axiome-tmp.* 2>/dev/null || true
    setsid bash -c "
      source '${helper_src}'
      tmpfile=''
      axiome_create_tracked_tempfile tmpfile '${dir}'
      sleep 0.03
      sleep 1
    " &
    pid=$!
    sleep "$delay"
    kill -TERM -- "-${pid}" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    [ -n "$(find "${dir}" -maxdepth 1 -name '.axiome-tmp.*' 2>/dev/null)" ] && new_leaks=$((new_leaks + 1))
    rm -f "${dir}"/.axiome-tmp.* 2>/dev/null || true
  done

  echo "old_leaks=${old_leaks} new_leaks=${new_leaks}" >&3
  [ "$old_leaks" -gt 0 ]
  [ "$new_leaks" -eq 0 ]
}
