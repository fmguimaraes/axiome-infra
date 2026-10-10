#!/usr/bin/env bash
# scripts/lib/report.sh — sourceable report/audit helper (AXI-1945).
# Generalises providers/aws/scripts/_power_lib.sh (same call shapes) so every
# lifecycle script gets one audit trail. Sourced, not executed.
#
#   report_init <scope> <op-label> [input=value ...]
#   report_section <title>
#   report_line <text>
#   report_override <name> <reason>      # any override used MUST go through this
#   report_finish [outcome]               # default outcome: "completed"
#   log_event <scope> <resource> <change>
#
# NFR4 (auditable): report_init always records actor + UTC time + every
# input given; report_finish always records an outcome.
# NFR3 (no secrets): every piece of text passed to the functions above is
# checked against obvious secret shapes before it is written; a match
# REFUSES the write (fail-closed — see _report_is_secret) rather than
# masking it. Under `set -e` callers, a refused report_line aborts the script.
# Auto-commit (the behaviour _power_lib.sh has by default) is OPT-IN here:
# set REPORT_AUTOCOMMIT=1. Tests never set it, so they never commit.

_rl_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPORT_REPO_ROOT="${REPORT_REPO_ROOT:-$(git -C "$_rl_dir" rev-parse --show-toplevel 2>/dev/null || echo "${_rl_dir}/../..")}"
REPORTS_DIR="${REPORTS_DIR:-${REPORT_REPO_ROOT}/reports}"
_REPORT_SEQ=0

_report_actor() {
  aws sts get-caller-identity --query Arn --output text 2>/dev/null || echo "${USER:-unknown}"
}

# --- NFR3 redaction guard: fail closed, never silently mask -------------------
# Named/shaped secrets, checked case-insensitively (nocasematch toggled only
# for this scan, never leaked to the caller). Deliberately NOT matched:
# `-p<value>` (too generic — collides with real flags like `-p <port>`),
# documented as debt in tests/README.md.
_report_is_secret() {
  local s="$1" matched=0
  shopt -s nocasematch
  if [[ "$s" =~ password[[:space:]]*= ]] || [[ "$s" =~ secret[[:space:]]*= ]] ||
     [[ "$s" =~ token[[:space:]]*= ]] || [[ "$s" =~ --password[[:space:]]+[^[:space:]] ]] ||
     [[ "$s" =~ postgres(ql)?://[^[:space:]/@]+:[^[:space:]/@]+@ ]] ||
     [[ "$s" =~ bearer[[:space:]]+[A-Za-z0-9._~+/-]{10,} ]] ||
     [[ "$s" =~ (akia|asia)[0-9a-z]{16} ]] ||
     [[ "$s" =~ eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+ ]]; then
    matched=1
  fi
  shopt -u nocasematch
  [ "$matched" -eq 1 ] && return 0
  _report_has_generic_secret "$s"
}
# A 40+-char run from the base64-ish alphabet is suspicious (an AWS secret
# access key is exactly this shape) UNLESS it is pure hex — a git SHA or a
# `sha256:<64 hex>` image digest is legitimate, routine audit content and
# must never be refused.
_report_has_generic_secret() {
  local s="$1" m
  while [[ "$s" =~ ([A-Za-z0-9/+=]{40,}) ]]; do
    m="${BASH_REMATCH[1]}"
    [[ "$m" =~ ^[0-9a-fA-F]+$ ]] || return 0
    s="${s/"$m"/}"
  done
  return 1
}
_report_refuse_secret() {
  if _report_is_secret "$1"; then
    echo "REPORT SECRET GUARD: refusing to write a line matching a secret shape." >&2
    return 1
  fi
  return 0
}

# --- append-only index (quick-scan trail; one row per change) ------------------
log_event() { # <scope> <resource> <change>
  local scope="$1" resource="$2" change="$3"
  _report_refuse_secret "${resource} ${change}" || return 1
  mkdir -p "$REPORTS_DIR"
  printf '| %s | %s | %s | %s | %s |\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$scope" "$resource" "$change" "$(_report_actor)" \
    >> "${REPORTS_DIR}/operations.md"
}

# --- per-run report file -------------------------------------------------------
report_init() { # <scope> <op-label> [input=value ...]
  _report_refuse_secret "$1 $2" || return 1
  mkdir -p "$REPORTS_DIR"
  _REPORT_SCOPE="$1"; _REPORT_OP="$2"; shift 2
  _REPORT_SEQ=$((_REPORT_SEQ + 1))
  _REPORT_BUF="$(mktemp)"
  _REPORT_FILE="${REPORTS_DIR}/$(date -u +%Y-%m-%d-%H%M%S)-$$-${_REPORT_SEQ}-${_REPORT_SCOPE}-${_REPORT_OP}.md"
  {
    echo "# ${_REPORT_SCOPE} / ${_REPORT_OP}"
    echo
    echo "- **When (UTC):** $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "- **Actor:** $(_report_actor)"
  } > "$_REPORT_BUF"
  [ "$#" -gt 0 ] && _report_init_inputs "$@"
  echo >> "$_REPORT_BUF"
}
_report_init_inputs() {
  echo "- **Inputs:**" >> "$_REPORT_BUF"
  for kv in "$@"; do
    _report_refuse_secret "$kv" || return 1
    echo "  - ${kv}" >> "$_REPORT_BUF"
  done
}
report_section() {
  _report_refuse_secret "$1" || return 1
  printf '\n## %s\n\n' "$1" >> "$_REPORT_BUF"
}
report_line() {
  _report_refuse_secret "$1" || return 1
  printf -- '- %s\n' "$1" >> "$_REPORT_BUF"
}
report_override() { # <name> <reason>
  _report_refuse_secret "$2" || return 1
  printf -- '- **OVERRIDE %s:** %s\n' "$1" "$2" >> "$_REPORT_BUF"
}
report_finish() { # [outcome]
  local outcome="${1:-completed}"
  _report_refuse_secret "$outcome" || return 1
  printf '\n**Outcome:** %s\n' "$outcome" >> "$_REPORT_BUF"
  mv "$_REPORT_BUF" "$_REPORT_FILE"
  echo "  report: ${_REPORT_FILE}"
  [ "${REPORT_AUTOCOMMIT:-0}" = "1" ] && _report_autocommit
  return 0
}

# Opt-in only (REPORT_AUTOCOMMIT=1) — scoped to just the two report paths.
_report_autocommit() {
  git -C "$REPORT_REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1 || return 0
  local idx="${REPORTS_DIR}/operations.md" paths=()
  [ -f "$_REPORT_FILE" ] && paths+=("$_REPORT_FILE")
  [ -f "$idx" ] && paths+=("$idx")
  [ "${#paths[@]}" -gt 0 ] || return 0
  git -C "$REPORT_REPO_ROOT" add -- "${paths[@]}"
  git -C "$REPORT_REPO_ROOT" diff --cached --quiet -- "${paths[@]}" && return 0
  git -C "$REPORT_REPO_ROOT" commit -q \
    -m "reports: ${_REPORT_SCOPE} ${_REPORT_OP} — $(basename "$_REPORT_FILE" .md)" \
    -- "${paths[@]}"
}
