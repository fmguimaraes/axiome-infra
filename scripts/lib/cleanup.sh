#!/usr/bin/env bash
# scripts/lib/cleanup.sh — shared, trap-composing temp-file cleanup registry
# (AXI-1973, FR63/AC58). Sourced, not executed; sourcing this file has NO
# side effects beyond defining functions/variables (same library contract as
# scripts/lib/report.sh and scripts/lock.sh — no trap is installed until a
# caller explicitly asks for one).
#
# Why this exists: report.sh and lock.sh each create exactly one temp file
# per call (report.sh's per-run buffer; lock.sh's lock-body read buffer).
# Both must disappear whether the sequence finishes normally, aborts under
# `set -e`, or the process is signalled (TERM/INT/HUP) mid-read — and both
# libraries are SOURCED by scripts that install their OWN EXIT/TERM traps
# (asset-sync.sh, deploy-prod.sh, power*.sh). A library that does a bare
# `trap ... EXIT` would silently destroy whatever trap the sourcing script
# already installed, or be silently destroyed by one installed afterward.
# This file is the one place that composing logic lives, so every library
# that creates a temp file uses the SAME mechanism instead of each growing
# its own trap-chaining code (lock.sh's lock_install_exit_trap already used
# this exact "capture trap -p, chain" technique for lock release; this
# generalises it to any signal and any number of registered paths/libraries).
#
# Contract:
#   axiome_register_cleanup <path>
#     -> this process just created <path> (a mktemp'd regular file) and it
#        must be removed on every exit path unless explicitly unregistered
#        first. Registering the same path twice is harmless (removal is
#        idempotent either way).
#   axiome_unregister_cleanup <path>
#     -> <path> was moved to its final location (report_finish's `mv`) or is
#        otherwise no longer this run's responsibility — stop tracking it.
#        A path never registered is a silent no-op.
#   axiome_run_cleanup
#     -> removes every still-registered path, THEN clears the registry
#        (idempotent: calling it twice removes nothing the second time).
#        Never removes a path that is empty/unset, and never removes a
#        directory — only a path that `[ -f ]` resolves true for, i.e. only
#        ever a plain file this process is the one that created via
#        mktemp/register. It is a plain function: call it directly (e.g. at
#        the end of a successful, non-exiting cleanup) or let the installed
#        trap call it for you.
#   axiome_install_cleanup_trap
#     -> idempotent. Installs the one shared handler on EXIT, INT, TERM and
#        HUP. For each signal, the CURRENT trap (if any — the sourcing
#        script's own, or a library sourced earlier, e.g. lock.sh's own
#        lock_install_exit_trap) is captured verbatim via `trap -p` and
#        chained: the shared handler runs axiome_run_cleanup first, then
#        re-invokes the previously captured command, then (EXIT only)
#        re-asserts the original exit status, or (INT/TERM/HUP) exits with
#        the conventional 128+signum code unless the chained command itself
#        already exited. Exactly like lock_install_exit_trap, the capture is
#        verbatim — no caller trap command is ever text-rewritten or
#        re-embedded in another trap string, so a single quote, `$VAR`,
#        newline or backslash in that command survives unchanged. Calling
#        this a second time detects its own handler already installed (by
#        signal) and does not re-wrap itself. A trap the caller installs
#        AFTER this call still wins for that signal (same caveat
#        lock_install_exit_trap documents) — call this as early as the
#        first registration, or call axiome_run_cleanup directly from your
#        own cleanup/trap instead.
#   axiome_create_tracked_tempfile <outvar> [dir]  (AXI-1973, review bounce
#     #2) -> the ONE sanctioned way to create a tracked temp file in this
#     repo. Every call site that used to do `tmpfile="$(mktemp)"` THEN
#     register it had a real signal-landing-in-the-gap leak window
#     (confirmed on scripts/lock.sh's `_lock_fetch`); this helper installs
#     the trap and registers the path BEFORE the file exists, so there is
#     no such gap. See the function's own header comment below for the
#     full contract, including how it avoids losing the registration in a
#     subshell.

_AXIOME_CLEANUP_PATHS=()

axiome_register_cleanup() {
  local p="$1"
  [ -n "$p" ] || return 0
  _AXIOME_CLEANUP_PATHS+=("$p")
}

# axiome_create_tracked_tempfile <outvar> [dir]  (AXI-1973, review bounce
# #2 — closes a real TERM-signal race, not just a test timing flake).
#
# THE RACE THIS CLOSES: every call site in this story used to do
# `tmpfile="$(mktemp)"` FIRST and only afterwards call
# `axiome_install_cleanup_trap`/`axiome_register_cleanup`. A signal landing
# in that gap — after the file exists on disk, before the trap/registry
# knows about it — leaked the file: there was no trap installed yet (or an
# installed trap with an empty registry) to catch it. The window is real
# in production, not just under a test's artificially slow aws stub; this
# helper removes it entirely by inverting the order: the trap is
# installed and the PATH is registered BEFORE the file is ever created, so
# there is no instant at which the file exists but is untracked.
#
# CONTRACT:
#   - Installs the shared trap (`axiome_install_cleanup_trap`, itself
#     idempotent) first.
#   - Picks a candidate path WITHOUT creating it, registers that path
#     (harmless even if nothing is ever created there —
#     `axiome_run_cleanup`'s `[ -f ]` guard is a no-op for a path that was
#     only ever registered, never created), and only THEN creates the file
#     — exclusively, via `set -C` (noclobber) inside a subshell, under a
#     private `umask 077` (matching `mktemp`'s own default 0600). Exclusive
#     creation never follows a pre-existing symlink at that path (the
#     underlying `open(2)` with the kernel's O_CREAT|O_EXCL refuses outright
#     if ANYTHING already exists there, symlink or not, without ever
#     dereferencing it) and never silently clobbers a same-named collision
#     — a collision is unregistered and a fresh random name is retried (up
#     to 20 times) instead.
#   - `set -C`/`umask 077` are scoped to the `( ... )` subshell only — this
#     helper never changes the CALLING script's umask or shell options
#     (same never-force-on-the-caller contract as everything else in this
#     library).
#   - On success, sets the CALLER-NAMED variable `<outvar>` to the created
#     path via `printf -v "<outvar>" ...` — a plain, same-shell variable
#     assignment, DELIBERATELY never `outvar="$(axiome_create_tracked_...)"`
#     command substitution. A command substitution would run this entire
#     function, INCLUDING the `axiome_register_cleanup` call, inside a
#     forked subshell — the array mutation would be invisible to the
#     parent shell the instant the subshell exits, silently reintroducing
#     the exact "registered but not really" gap this helper exists to
#     close. `printf -v` (a plain builtin, bash 3.1+, no namerefs — a
#     `local -n` nameref would not even parse on bash < 4.3, e.g. macOS's
#     stock /bin/bash 3.2) keeps every step, including the registration,
#     in the caller's own shell. tests/cleanup_lib.bats UT-INFRA-624
#     exercises this directly.
#   - On failure (20 collisions in a row — in practice should never
#     happen), unregisters the last candidate and returns 1 with `<outvar>`
#     unset; the caller is responsible for its own existing fail-closed
#     error message (unchanged call-site texts — see scripts/lock.sh's
#     `_lock_fetch`).
axiome_create_tracked_tempfile() {
  local _axiome_cto_outvar="$1" _axiome_cto_dir="${2:-${TMPDIR:-/tmp}}"
  axiome_install_cleanup_trap
  local tries=0 candidate
  while :; do
    tries=$((tries + 1))
    candidate="${_axiome_cto_dir}/.axiome-tmp.$$.${RANDOM}${RANDOM}${RANDOM}"
    axiome_register_cleanup "${candidate}"
    if ( umask 077 && set -C && : > "${candidate}" ) 2>/dev/null; then
      printf -v "${_axiome_cto_outvar}" '%s' "${candidate}"
      return 0
    fi
    axiome_unregister_cleanup "${candidate}"
    [ "${tries}" -ge 20 ] && return 1
  done
}

axiome_unregister_cleanup() {
  local p="$1" kept=() x
  [ -n "$p" ] || return 0
  [ "${#_AXIOME_CLEANUP_PATHS[@]}" -eq 0 ] && return 0
  for x in "${_AXIOME_CLEANUP_PATHS[@]}"; do
    [ "$x" = "$p" ] && continue
    kept+=("$x")
  done
  # bash < 4.4 raises "unbound variable" under `set -u` when expanding an
  # EMPTY array via "${kept[@]}" (a known old-bash quirk, still relevant on
  # macOS's stock /bin/bash) — the `+` parameter-expansion guard below only
  # expands the array when it is set/non-empty, otherwise substitutes
  # nothing, so this is safe whether `kept` ended up empty or not.
  _AXIOME_CLEANUP_PATHS=("${kept[@]+"${kept[@]}"}")
}

# Removes only entries that are (a) a non-empty path string and (b) an
# existing PLAIN FILE — never an empty variable, never a directory — then
# clears the registry. Safe to call more than once.
axiome_run_cleanup() {
  local p
  if [ "${#_AXIOME_CLEANUP_PATHS[@]}" -gt 0 ]; then
    for p in "${_AXIOME_CLEANUP_PATHS[@]}"; do
      [ -n "$p" ] || continue
      [ -f "$p" ] && rm -f -- "$p"
    done
  fi
  _AXIOME_CLEANUP_PATHS=()
}

_AXIOME_CLEANUP_PREV_EXIT=""
_AXIOME_CLEANUP_PREV_INT=""
_AXIOME_CLEANUP_PREV_TERM=""
_AXIOME_CLEANUP_PREV_HUP=""
_AXIOME_CLEANUP_INSTALLED=0

# Runs a verbatim-captured `trap -p <SIG>` command string (same unquoting
# trick lock.sh's _lock_run_saved_exit_trap uses: `eval "set -- $saved"`
# lets the shell redo the unquoting bash already did when it produced
# `trap -p`'s output, landing the original command text in $3 untouched).
#
# <rc> (rework, review bounce #1 follow-up) MUST be passed and is restored
# as `$?` with `( exit "$rc" )` immediately before the chained command
# runs. Why: the chained command may itself be another "read $? fresh at
# entry, exit at the end" handler — e.g. scripts/lock.sh's own
# _lock_exit_trap_handler, when lock_install_exit_trap ran BEFORE
# report_init so lock's handler ends up the inner, chained-to command.
# Without this restoration, by the time that inner handler's own
# `local rc=$?` runs, `$?` has already been overwritten by
# axiome_run_cleanup and the `eval "set -- ..."` calls above — so the inner
# handler would read a stale (often 0) status and silently convert a real
# script failure into an apparent success. `( exit "$rc" )` is the
# standard no-op-subshell idiom for setting `$?` in the CURRENT shell
# without actually exiting it — but it is itself a command whose exit
# status equals `rc`, so under a `set -e` caller (the common case for
# every script that sources this library) a non-zero `rc` would abort the
# handler right there, on that bare statement, before the chained `eval`
# ever runs. `set +e` around it (restored after, same
# save/restore-never-force idiom scripts/lock.sh's own `_aws_run` already
# uses) neutralises that.
_axiome_cleanup_run_saved() {
  local saved="$1" rc="${2:-0}" cmd was_e
  [ -n "$saved" ] || return 0
  eval "set -- ${saved}"
  cmd="$3"
  case "$-" in *e*) was_e=1 ;; *) was_e=0 ;; esac
  set +e
  ( exit "${rc}" )
  eval "${cmd}"
  [ "${was_e}" = "1" ] && set -e
  return 0
}

_axiome_cleanup_trap_exit() {
  local rc=$?
  axiome_run_cleanup
  _axiome_cleanup_run_saved "${_AXIOME_CLEANUP_PREV_EXIT}" "${rc}"
  exit "${rc}"
}

# shellcheck disable=SC2120 # called only from the fixed `trap '... INT' INT`
# etc strings this file installs itself — never with a caller-supplied arg.
_axiome_cleanup_trap_signal() { # <signal-name> <conventional-exit-code>
  local sig="$1" code="$2" saved=""
  axiome_run_cleanup
  case "$sig" in
    INT)  saved="${_AXIOME_CLEANUP_PREV_INT}" ;;
    TERM) saved="${_AXIOME_CLEANUP_PREV_TERM}" ;;
    HUP)  saved="${_AXIOME_CLEANUP_PREV_HUP}" ;;
  esac
  _axiome_cleanup_run_saved "${saved}"
  exit "${code}"
}

axiome_install_cleanup_trap() {
  [ "${_AXIOME_CLEANUP_INSTALLED}" = "1" ] && return 0
  _AXIOME_CLEANUP_INSTALLED=1
  local current
  current="$(trap -p EXIT)"
  case "${current}" in *_axiome_cleanup_trap_exit*) ;; *) _AXIOME_CLEANUP_PREV_EXIT="${current}" ;; esac
  trap '_axiome_cleanup_trap_exit' EXIT
  current="$(trap -p INT)"
  case "${current}" in *_axiome_cleanup_trap_signal*) ;; *) _AXIOME_CLEANUP_PREV_INT="${current}" ;; esac
  trap '_axiome_cleanup_trap_signal INT 130' INT
  current="$(trap -p TERM)"
  case "${current}" in *_axiome_cleanup_trap_signal*) ;; *) _AXIOME_CLEANUP_PREV_TERM="${current}" ;; esac
  trap '_axiome_cleanup_trap_signal TERM 143' TERM
  current="$(trap -p HUP)"
  case "${current}" in *_axiome_cleanup_trap_signal*) ;; *) _AXIOME_CLEANUP_PREV_HUP="${current}" ;; esac
  trap '_axiome_cleanup_trap_signal HUP 129' HUP
}
