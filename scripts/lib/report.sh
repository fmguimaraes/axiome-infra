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
#   report_is_secret_value <value>        # PUBLIC (AXI-1973, FR63) — see below
#
# NFR4 (auditable): report_init always records actor + UTC time + every
# input given; report_finish always records an outcome.
# NFR3 (no secrets): every piece of text passed to the functions above is
# checked against obvious secret shapes before it is written; a match
# REFUSES the write (fail-closed) rather than masking it. Under `set -e`
# callers, a refused report_line aborts the script.
#
# report_is_secret_value <value> (AXI-1973, FR63/AC58) — PUBLIC, documented
# contract: refuses VALUE when either of two independent checks matches —
# neither check alone is the whole contract:
#   (a) VALUE-SHAPE: the value's OWN shape, regardless of any key/flag/field
#       name attached to it, matches one of:
#         - a postgres/postgresql URL with an embedded user:pass@
#         - an HTTP "Bearer <token>" credential
#         - an AWS access-key id (AKIA/ASIA + 16 more alnum chars)
#         - a JWT (three base64url segments joined by '.')
#         - a long (40+ char) run from the base64/hex alphabet that is NOT a
#           recognised hash-digest length (exactly 40 = git SHA-1, 64 =
#           SHA-256 — those two lengths are allowed through as routine audit
#           content, e.g. a deployed commit or an image digest; any OTHER
#           all-hex length of that size is refused)
#       This catches a credential WHATEVER key/flag it is attached to (or
#       none at all) — e.g. a bare postgres URL with no key= in front of it.
#   (b) SENSITIVE-KEY-PAIR: the string contains a `key=value`, `key: value`
#       (JSON-style), `--flag value` or `--flag=value` pair whose KEY,
#       matched WHOLE (never as a trailing substring of a longer word),
#       case-insensitively, with `-`/`_` treated alike, is one of the
#       recognised sensitive names (`password`, `passwd`, `pwd`,
#       `pgpassword`, `secret`, `token`, `apikey`/`api_key`, `access_key`,
#       `secret_key`, `private_key`, `auth`) or ENDS with `_password`,
#       `_passwd`, `_secret`, `_token`, `_apikey`/`_api_key`, `_secret_key`
#       or `_private_key` — AND whose VALUE is not empty, not a recognised
#       non-secret placeholder (`none`, `null`, `unset`, `redacted`,
#       `rotated`, `changed`, `strict`, `enabled`, `disabled`, `true`,
#       `false`, `yes`, `no`), and not a masked form (`***`/`xxx`/a
#       `<...>`/`[...]` placeholder). This is deliberately NOT a
#       substring/regex match against the whole line: `password_policy=strict`
#       does not match the key `password` (it is a different, whole key,
#       `password_policy`) and is never refused by this branch; `my
#       password=hunter2`, `PGPASSWORD=x`, `--password x` and
#       `override_token=abc123` all DO match and ARE refused by this branch
#       even though `abc123`/`hunter2` are far too short/low-entropy to ever
#       be caught by the value-shape check in (a) alone. When in doubt
#       (ambiguous key, ambiguous value) this branch refuses — the operator
#       can always rephrase.
# A key-name match with NO sensitive-looking value attached (per the
# allowlist above) is NOT refused — that is the one-sided bug this replaced:
# the old check refused ANY `password=`/`secret=`/`token=` assignment
# WHATEVER the value was, including the innocuous `override_token=none` and
# `password_policy=strict`. report_is_secret_value never writes anything and
# has no side effects; it is called internally by every report_* write path
# above via _report_refuse_secret, and callers outside this file
# (scripts/lock.sh, providers/aws/scripts/power.sh) MUST call this public
# function directly instead of reaching into a private helper or
# re-implementing the check.
#
# Auto-commit (the behaviour _power_lib.sh has by default) is OPT-IN here:
# set REPORT_AUTOCOMMIT=1. Tests never set it, so they never commit.
#
# Temp files (AXI-1973, FR63/AC58): report_init's per-run buffer (mktemp) is
# registered with scripts/lib/cleanup.sh the moment it is created and
# unregistered only once report_finish has moved it to its final path. An
# abandoned sequence (report_init called, report_finish never reached —
# whether because the script errored out, or because a later report_* call
# itself refused a secret-shaped line) leaves the buffer registered, so the
# shared cleanup trap (installed the first time report_init runs; see
# scripts/lib/cleanup.sh for how it composes with whatever EXIT/INT/TERM/HUP
# trap the sourcing script already has) removes it on every exit path,
# including a signal.

_rl_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPORT_REPO_ROOT="${REPORT_REPO_ROOT:-$(git -C "$_rl_dir" rev-parse --show-toplevel 2>/dev/null || echo "${_rl_dir}/../..")}"
REPORTS_DIR="${REPORTS_DIR:-${REPORT_REPO_ROOT}/reports}"
_REPORT_SEQ=0

# shellcheck source=cleanup.sh
. "${_rl_dir}/cleanup.sh"

_report_actor() {
  aws sts get-caller-identity --query Arn --output text 2>/dev/null || echo "${USER:-unknown}"
}

# --- NFR3/FR63 redaction guard: fail closed, never silently mask --------------
# PUBLIC (see the header comment above for the full contract). Judges VALUE
# shape only — never a key/flag name. Checked case-insensitively
# (nocasematch toggled only for this scan, never leaked to the caller).
report_is_secret_value() {
  local s="$1" matched=0
  shopt -s nocasematch
  if [[ "$s" =~ postgres(ql)?://[^[:space:]/@]+:[^[:space:]/@]+@ ]] ||
     [[ "$s" =~ bearer[[:space:]]+[A-Za-z0-9._~+/-]{10,} ]] ||
     [[ "$s" =~ (akia|asia)[0-9a-z]{16} ]] ||
     [[ "$s" =~ eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+ ]]; then
    matched=1
  fi
  shopt -u nocasematch
  [ "$matched" -eq 1 ] && return 0
  _report_has_generic_secret "$s" && return 0
  _report_has_sensitive_key_value "$s"
}

# --- sensitive key=value / --flag value pair detection (AXI-1973 rework) -----
# Whole-key matching (never a trailing-substring regex): the key token is
# the contiguous run of [A-Za-z0-9_-] immediately before the `=`/`:`
# operator (optionally through a closing quote, for JSON `"key": "value"`),
# or immediately after a `--` flag prefix. Normalises `-` to `_` and
# lower-cases before comparing against the recognised name/suffix sets.
_report_key_is_sensitive() {
  local k="${1,,}"
  k="${k//-/_}"
  case "$k" in
    password|passwd|pwd|pgpassword|secret|token|apikey|api_key|access_key|secret_key|private_key|auth)
      return 0 ;;
    *_password|*_passwd|*_secret|*_token|*_apikey|*_api_key|*_secret_key|*_private_key)
      return 0 ;;
    *) return 1 ;;
  esac
}
# A value is ALLOWED (not a leak) only when empty, a recognised closed-set
# placeholder word, or a fully masked (*/x/X only) or <...>/[...] form.
# Anything else under a sensitive key is refused — no "looks like prose"
# exception.
_report_value_is_allowed() {
  local v="$1" vn
  v="${v%\"}"; v="${v#\"}"
  v="${v%\'}"; v="${v#\'}"
  v="${v%%[,;.)]}"
  [ -z "$v" ] && return 0
  vn="${v,,}"
  case "$vn" in
    none|null|unset|redacted|rotated|changed|strict|enabled|disabled|true|false|yes|no)
      return 0 ;;
  esac
  [[ "$v" =~ ^[*xX]+$ ]] && return 0
  [[ "$v" =~ ^\<.*\>$ ]] && return 0
  [[ "$v" =~ ^\[.*\]$ ]] && return 0
  return 1
}
# Scans the whole string for key=value (bare or quoted key/value, optional
# `--` prefix), "key": value (JSON — key MUST be quoted here: an unquoted
# "word:" in ordinary prose, e.g. "note this: token=..." must never be
# treated as a key/value pair — that would let the prose colon swallow a
# REAL assignment right after it into its own value capture and hide it
# from the scan) and bare `--flag value` pairs. Returns 0 (is a leak) on
# the first sensitive key paired with a non-allowed value.
_report_has_sensitive_key_value() {
  local s="$1" whole key val
  local qc='"'
  local valchars="[^${qc},;)[:space:]]"
  # key=value / --flag=value (key never required to be quoted; '=' only)
  while [[ "$s" =~ (^|[^A-Za-z0-9_-])(--)?([A-Za-z][A-Za-z0-9_-]*)[[:space:]]*=[[:space:]]*${qc}?(${valchars}*)${qc}? ]]; do
    whole="${BASH_REMATCH[0]}"
    key="${BASH_REMATCH[3]}"
    val="${BASH_REMATCH[4]}"
    if _report_key_is_sensitive "$key" && ! _report_value_is_allowed "$val"; then
      return 0
    fi
    s="${s/"$whole"/}"
  done
  # "key": value (JSON-style — key must be quoted; ':' only)
  while [[ "$s" =~ ${qc}([A-Za-z][A-Za-z0-9_-]*)${qc}[[:space:]]*:[[:space:]]*${qc}?(${valchars}*)${qc}? ]]; do
    whole="${BASH_REMATCH[0]}"
    key="${BASH_REMATCH[1]}"
    val="${BASH_REMATCH[2]}"
    if _report_key_is_sensitive "$key" && ! _report_value_is_allowed "$val"; then
      return 0
    fi
    s="${s/"$whole"/}"
  done
  # bare --flag value (space-separated, no operator)
  while [[ "$s" =~ (^|[[:space:]])--([A-Za-z][A-Za-z0-9_-]*)[[:space:]]+${qc}?(${valchars}+)${qc}? ]]; do
    whole="${BASH_REMATCH[0]}"
    key="${BASH_REMATCH[2]}"
    val="${BASH_REMATCH[3]}"
    if _report_key_is_sensitive "$key" && ! _report_value_is_allowed "$val"; then
      return 0
    fi
    s="${s/"$whole"/}"
  done
  return 1
}
# A 40+-char run from the base64-ish alphabet is suspicious (an AWS secret
# access key is exactly this shape) UNLESS it is pure hex AND exactly a
# recognised hash-digest length (40 = git SHA-1, 64 = SHA-256) — a git SHA or
# a `sha256:<64 hex>` image digest is legitimate, routine audit content and
# must never be refused. A pure-hex run of any OTHER length is NOT exempt
# (FR63 — closes the gap where an all-hex secret at a non-hash length used
# to slip through unconditionally).
_report_has_generic_secret() {
  local s="$1" m len
  while [[ "$s" =~ ([A-Za-z0-9/+=]{40,}) ]]; do
    m="${BASH_REMATCH[1]}"
    if [[ "$m" =~ ^[0-9a-fA-F]+$ ]]; then
      len=${#m}
      [ "$len" -eq 40 ] || [ "$len" -eq 64 ] || return 0
    else
      return 0
    fi
    s="${s/"$m"/}"
  done
  return 1
}
_report_refuse_secret() {
  if report_is_secret_value "$1"; then
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
  # AXI-1973/FR63, review bounce #2: axiome_create_tracked_tempfile
  # installs the shared trap and registers the path BEFORE the buffer
  # file is created — see scripts/lib/cleanup.sh's own header for why a
  # bare `mktemp` THEN register leaves a real signal-landing-in-the-gap
  # leak window.
  axiome_create_tracked_tempfile _REPORT_BUF || {
    echo "ERROR: could not create a temp file for the report buffer" >&2
    return 1
  }
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
  axiome_unregister_cleanup "$_REPORT_BUF"
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
