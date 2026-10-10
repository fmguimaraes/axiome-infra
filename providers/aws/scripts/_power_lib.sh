#!/usr/bin/env bash
# _power_lib.sh — shared reporting/audit helpers for power.sh & power-data.sh.
# Sourced, not executed. Provides:
#   - REPO_ROOT / REPORTS_DIR (resolved to the running checkout via git)
#   - pl_log_event <env> <resource> <change>   -> one row in the append-only index
#   - pl_report_init / pl_report_section / pl_report_line / pl_report_finish
#     -> one self-contained markdown report file per run
#
# Naming (AXI-1973, FR63): these were named report_init/report_section/
# report_line/report_finish/log_event — the EXACT same names
# scripts/lib/report.sh defines. power.sh sources both files (lock.sh, for
# lock_require_free/LOCK_RC_*, pulls in scripts/lib/report.sh transitively;
# then this file, for ITS OWN report shape — see power.sh's header). Sourcing
# two files that define the same function names means whichever is sourced
# SECOND silently wins for BOTH — there is no way to source "half" of either
# file — so lock.sh's internal report_init/report_override/report_finish
# calls (used by lock_override's audit trail) would have been silently
# rebound to THIS file's simpler versions (no secret-shape guard at all)
# whenever both were sourced together. Prefixing every function here with
# `pl_` removes the name collision outright: power.sh and power-up-all.sh
# (this file's only two callers) now call pl_report_*/pl_log_event
# explicitly, scripts/lib/report.sh's report_*/log_event/report_is_secret_value
# are never shadowed by this file again, and the sourcing-order workaround
# power.sh's header used to document is no longer needed.

_pl_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(git -C "$_pl_dir" rev-parse --show-toplevel 2>/dev/null || echo "${_pl_dir}/../../..")}"
REPORTS_DIR="${REPORTS_DIR:-${REPO_ROOT}/reports}"

# shellcheck source=../../../scripts/lib/cleanup.sh
. "${REPO_ROOT}/scripts/lib/cleanup.sh"

_actor() { aws sts get-caller-identity --query Arn --output text 2>/dev/null || echo unknown; }

# --- append-only index (quick-scan trail; one row per change) ------------------
pl_log_event() { # <env> <resource> <change>
  mkdir -p "$REPORTS_DIR"
  printf '| %s | %s | %s | %s | %s |\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" "$3" "$(_actor)" \
    >> "${REPORTS_DIR}/power-operations.md"
}

# --- per-run report file -------------------------------------------------------
# pl_report_init <env> <op-label>   e.g. pl_report_init production compute-down
pl_report_init() {
  mkdir -p "$REPORTS_DIR"
  _REPORT_ENV="$1"; _REPORT_OP="$2"
  # AXI-1973/FR63: same no-leftover-temp-file contract as
  # scripts/lib/report.sh — pl_report_finish unregisters the buffer once
  # mv has moved it to its final path. Composes with whatever EXIT/TERM
  # trap the sourcing script already has (see scripts/lib/cleanup.sh).
  # Review bounce #2: axiome_create_tracked_tempfile installs the trap
  # and registers the path BEFORE the buffer file is created — a bare
  # `mktemp` THEN register leaves a real signal-landing-in-the-gap leak
  # window (see scripts/lib/cleanup.sh's own header for the full story).
  axiome_create_tracked_tempfile _REPORT_BUF || {
    echo "ERROR: could not create a temp file for the report buffer" >&2
    return 1
  }
  _REPORT_FILE="${REPORTS_DIR}/$(date -u +%Y-%m-%d-%H%M%S)-${1}-${2}.md"
  {
    echo "# Power op — ${1} / ${2}"
    echo
    echo "- **When (UTC):** $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "- **Actor:** $(_actor)"
    echo "- **Region:** ${REGION:-unknown}"
    echo
  } > "$_REPORT_BUF"
}
pl_report_section() { printf '\n## %s\n\n' "$1" >> "$_REPORT_BUF"; }
pl_report_line()    { printf -- '- %s\n' "$1" >> "$_REPORT_BUF"; }
pl_report_finish() {
  mv "$_REPORT_BUF" "$_REPORT_FILE"
  axiome_unregister_cleanup "$_REPORT_BUF"
  echo "  report: ${_REPORT_FILE}"
  _pl_report_autocommit
}

# Auto-commit the per-run report + index row to the current branch. Scoped to
# just those two paths (pathspec), so it never sweeps up unrelated staged work.
# Opt out with POWER_NO_COMMIT=1; silently skips if REPO_ROOT isn't a git repo.
# Named _pl_ (not _report_autocommit) — scripts/lib/report.sh defines a
# PRIVATE function of that exact name; the same collision this file's
# public report_* functions had (see the header) applies to this one too.
_pl_report_autocommit() {
  [ "${POWER_NO_COMMIT:-0}" = "1" ] && { echo "  (auto-commit off: POWER_NO_COMMIT=1)"; return 0; }
  git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1 || { echo "  (auto-commit skipped: not a git repo)"; return 0; }
  local idx="${REPORTS_DIR}/power-operations.md" paths=()
  [ -f "$_REPORT_FILE" ] && paths+=("$_REPORT_FILE")
  [ -f "$idx" ] && paths+=("$idx")
  [ "${#paths[@]}" -gt 0 ] || { echo "  (auto-commit: nothing to commit)"; return 0; }
  git -C "$REPO_ROOT" add -- "${paths[@]}"
  if git -C "$REPO_ROOT" diff --cached --quiet -- "${paths[@]}"; then
    echo "  (auto-commit: nothing to commit)"; return 0
  fi
  git -C "$REPO_ROOT" commit -q \
    -m "reports: ${_REPORT_ENV} ${_REPORT_OP} — $(basename "$_REPORT_FILE" .md)" \
    -- "${paths[@]}" \
    && echo "  committed report to $(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD)"
}
