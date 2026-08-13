#!/usr/bin/env bash
# _power_lib.sh — shared reporting/audit helpers for power.sh & power-data.sh.
# Sourced, not executed. Provides:
#   - REPO_ROOT / REPORTS_DIR (resolved to the running checkout via git)
#   - log_event <env> <resource> <change>   -> one row in the append-only index
#   - report_init / report_section / report_line / report_finish
#     -> one self-contained markdown report file per run

_pl_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$_pl_dir" rev-parse --show-toplevel 2>/dev/null || echo "${_pl_dir}/../../..")"
REPORTS_DIR="${REPORTS_DIR:-${REPO_ROOT}/reports}"

_actor() { aws sts get-caller-identity --query Arn --output text 2>/dev/null || echo unknown; }

# --- append-only index (quick-scan trail; one row per change) ------------------
log_event() { # <env> <resource> <change>
  mkdir -p "$REPORTS_DIR"
  printf '| %s | %s | %s | %s | %s |\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" "$3" "$(_actor)" \
    >> "${REPORTS_DIR}/power-operations.md"
}

# --- per-run report file -------------------------------------------------------
# report_init <env> <op-label>   e.g. report_init production compute-down
report_init() {
  mkdir -p "$REPORTS_DIR"
  _REPORT_BUF="$(mktemp)"
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
report_section() { printf '\n## %s\n\n' "$1" >> "$_REPORT_BUF"; }
report_line()    { printf -- '- %s\n' "$1" >> "$_REPORT_BUF"; }
report_finish() {
  mv "$_REPORT_BUF" "$_REPORT_FILE"
  echo "  report: ${_REPORT_FILE}"
}
