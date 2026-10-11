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
# AXI-1972 (scope item follow-up d): the original version of this test
# picked its signal-delivery moment with a $RANDOM sub-millisecond jitter
# and HOPED it landed inside the (deliberately widened) unguarded window —
# a probabilistic sanity assertion: on any single iteration, real OS
# scheduling (process fork/exec latency for `setsid bash -c "..."`, which
# the outer `sleep "$delay"` does not account for) could push the actual
# "where is the subprocess now" point outside the window the delay was
# chosen to land in, with no bound on how often. 200 iterations made a
# false pass unlikely in practice, not impossible, and said so honestly in
# the old comment.
#
# This version replaces "guess a delay and hope" with explicit
# synchronization: each subprocess writes a MARKER FILE at the exact
# instant its pre-fix shape reaches the unguarded point (mktemp done, trap
# not yet installed) and only THEN sleeps; the outer loop polls for that
# marker (bounded, short interval) and sends the signal the instant it
# appears. The signal is now GUARANTEED to land inside the window on every
# iteration — this is no longer a timing guess, it is "wait until we know
# we are there, then act". The new (fixed) shape is driven the same way,
# signalled the instant ITS marker appears (written immediately after
# axiome_create_tracked_tempfile returns) — proving no leak regardless of
# how early the signal lands relative to that point, deterministically.
@test "UT-INFRA-625: the create-then-register race is closed (deterministic, marker-synchronized)" {
  local dir="${BATS_TEST_TMPDIR}/race"
  mkdir -p "$dir"
  local helper_src="${INFRA_ROOT}/scripts/lib/cleanup.sh"

  # _wait_for_marker <path> — polls (10ms interval, 5s bound) until <path>
  # exists. Returns non-zero on timeout (never silently proceeds).
  _wait_for_marker() {
    local path="$1" waited=0
    while [ ! -e "$path" ]; do
      sleep 0.01
      waited=$((waited + 1))
      [ "$waited" -lt 500 ] || return 1
    done
    return 0
  }

  local old_leaks=0 new_leaks=0 i pid marker
  for i in $(seq 1 20); do
    # OLD shape: mktemp, write a marker, THEN sleep before trap/register
    # — the marker's appearance IS the unguarded-window entry point.
    rm -f "${dir}"/old.* "${dir}"/marker.old 2>/dev/null || true
    marker="${dir}/marker.old"
    setsid bash -c "
      source '${helper_src}'
      tmpfile=\"\$(mktemp '${dir}/old.XXXXXX')\"
      : > '${marker}'
      sleep 1
      axiome_install_cleanup_trap
      axiome_register_cleanup \"\${tmpfile}\"
      sleep 1
    " &
    pid=$!
    _wait_for_marker "$marker" || fail "OLD shape never reached its marker (iteration ${i})"
    kill -TERM -- "-${pid}" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    [ -n "$(find "${dir}" -maxdepth 1 -name 'old.*' 2>/dev/null)" ] && old_leaks=$((old_leaks + 1))
    rm -f "${dir}"/old.* "${marker}" 2>/dev/null || true

    # NEW shape: axiome_create_tracked_tempfile (register-before-create),
    # marker written the instant it returns — signalled immediately after,
    # proving no leak at the earliest point a signal could plausibly race
    # this call from the outside.
    rm -f "${dir}"/.axiome-tmp.* "${dir}"/marker.new 2>/dev/null || true
    marker="${dir}/marker.new"
    setsid bash -c "
      source '${helper_src}'
      tmpfile=''
      axiome_create_tracked_tempfile tmpfile '${dir}'
      : > '${marker}'
      sleep 1
    " &
    pid=$!
    _wait_for_marker "$marker" || fail "NEW shape never reached its marker (iteration ${i})"
    kill -TERM -- "-${pid}" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    [ -n "$(find "${dir}" -maxdepth 1 -name '.axiome-tmp.*' 2>/dev/null)" ] && new_leaks=$((new_leaks + 1))
    rm -f "${dir}"/.axiome-tmp.* "${marker}" 2>/dev/null || true
  done

  echo "old_leaks=${old_leaks} new_leaks=${new_leaks}" >&3
  [ "$old_leaks" -eq 20 ]
  [ "$new_leaks" -eq 0 ]
}
