#!/usr/bin/env bash
# scripts/lock.sh — exclusive S3-object locks for the production lifecycle
# (FR28/FR29/FR30, EC7, AC19/AC20).
#
# Three operations can otherwise run against the one production box at once:
# two deploys (scripts/deploy-prod.sh), a deploy during a power-down
# (providers/aws/scripts/power.sh), and — the dangerous one — a `terraform
# apply` from `terraform-cd` while the data tier is parked
# (providers/aws/scripts/power-data.sh snapshots+deletes Redis and stops RDS,
# then recreates on unpark; an apply in that window "repairs" what it sees as
# drift and collides with the restore). This script is the single lock
# primitive both AXI-1951 (power/deploy scripts) and the `terraform-cd`
# workflow (this story) call.
#
# THIS FILE IS A SOURCED LIBRARY FIRST, A CLI SECOND. AXI-1951/AXI-1954
# `source` it from deploy/power scripts that already run their own traps,
# already use bare `PROJECT`/`REGION` variables, and are not always under
# `set -e`. Every rule below exists because of one of those three facts:
#   - every variable this library SETS is `local` to a function or
#     `_LOCK_`-prefixed (never bare `PROJECT`/`REGION`/`ENV`/`NAME`/`TOKEN`)
#     so sourcing this file can never silently overwrite the caller's own
#     same-named variables (see lock_env_defaults below).
#   - nothing in here calls `exit` except inside the `main`-guarded CLI
#     block at the bottom; every internal failure is a `return` with one of
#     the four LOCK_RC_* codes, so a sourced caller is never killed.
#   - nothing in here force-enables `-e`; `_lock_was_errexit` saves and
#     restores exactly the caller's own setting around every raw `aws` call.
#   - this file installs NO trap by default. `lock_install_exit_trap` is
#     opt-in and explicitly CHAINS onto whatever EXIT trap the caller
#     already has (see "auto-release" below) instead of overwriting it.
#
# ---------------------------------------------------------------------------
# CLI
#   scripts/lock.sh <dev|staging|production> acquire  <deploy|data-tier|apply> --operation <text>
#   scripts/lock.sh <dev|staging|production> release  <deploy|data-tier|apply> --token <token>
#   scripts/lock.sh <dev|staging|production> status   [<deploy|data-tier|apply>]
#   scripts/lock.sh <dev|staging|production> override <deploy|data-tier|apply> --reason <text> --confirm
#
#   acquire prints `ACQUIRED <name> token=<token> actor=<actor> at=<iso>` on
#   stdout on success — the caller MUST capture <token> (it is the only proof
#   of ownership release/override-protection accepts).
#
# Library (source this file; `main` is guarded so sourcing has NO side
# effects beyond defining functions/constants):
#   . scripts/lock.sh
#   lock_acquire  <env> <name> <operation>            -> sets stdout as above, returns $LOCK_RC_*
#   lock_release  <env> <name> <token>                -> returns $LOCK_RC_*
#   lock_status   <env> [<name>]                      -> prints, returns $LOCK_RC_*
#   lock_override <env> <name> <reason> <yes|no>      -> returns $LOCK_RC_*
#   lock_require_free <env> <name>                    -> refuse (nonzero) unless FREE
#   lock_acquire_exclusive <env> <name> <operation> <other...>
#     -> acquire <name> FIRST, then require every <other> free (AXI-1967,
#        FR42/FR43/AC34/AC35); on any <other> held/UNKNOWN, releases <name>
#        (this call's own token) and returns that rc. Same stdout contract
#        as lock_acquire on success.
#
#   Auto-release (REPLACES the earlier `lock_release_on_exit` shape — bash
#   has no trap STACK, so a function that does a bare `trap ... EXIT` can
#   silently destroy a trap the caller already installed, or be silently
#   destroyed by one the caller installs later, either way leaking the
#   lock. This is the contract AXI-1951/AXI-1954 must use instead):
#     lock_mark_for_auto_release <env> <name> <token>
#       -> registers a lock to be released by lock_release_held. REFUSES
#          name=data-tier (FR29 — see below) instead of registering it.
#     lock_release_held
#       -> releases every lock registered above, then clears the registry.
#          Idempotent: safe to call with nothing registered (no-op, rc 0)
#          and safe to call twice (the second call is a no-op because the
#          first call already cleared the registry — it never attempts a
#          second delete).
#     lock_install_exit_trap
#       -> installs a FIXED handler function (`_lock_exit_trap_handler`) as
#          the EXIT trap. It does not text-rewrite or re-embed whatever the
#          caller's existing EXIT trap command CONTAINS (that command can
#          hold anything — a single quote, `$VAR`, a newline, a backslash —
#          and none of it is ever interpolated into another trap string).
#          Instead the COMPLETE, already-correctly-quoted `trap -p EXIT`
#          output is captured verbatim into `_LOCK_PREV_EXIT_TRAP` once, and
#          the handler restores it with `eval "set -- $_LOCK_PREV_EXIT_TRAP"`
#          (the shell itself does the unquoting bash already produced,
#          giving back the original command as `$3`) before `eval`-ing that
#          command — the same mechanism `trap -p`'s own output is designed
#          to be fed back into. The handler preserves the ORIGINAL exit
#          status across the whole sequence (captured as `$?` at entry,
#          re-asserted via `exit` at the end unless the restored trap itself
#          calls `exit`). Calling `lock_install_exit_trap` a SECOND time
#          detects its own handler already installed and does not re-wrap
#          it (no self-chaining, no double release). Also sets
#          `trap 'exit 130' INT` / `trap 'exit 143' TERM` so a Ctrl-C/
#          SIGTERM still runs the EXIT trap instead of leaking the lock
#          (bash does not run an EXIT trap on a bare signal otherwise).
#          CAVEATS callers must know (AXI-1951/AXI-1954):
#            - it reads the existing EXIT trap AT CALL TIME — an EXIT trap
#              the caller installs AFTERWARDS replaces the release outright;
#              call `lock_install_exit_trap` LAST, or call
#              `lock_release_held` from your own cleanup instead.
#            - it replaces the caller's own INT and TERM handlers (it does
#              not chain those two, only EXIT).
#            - the registry (`lock_mark_for_auto_release`) is per PROCESS —
#              a lock marked inside a subshell or `$(...)` is never seen by
#              the parent shell's `lock_release_held`/exit trap.
#            - `data-tier` has no automatic release by ANY route (see FR29
#              below) — `lock_mark_for_auto_release` refuses to register it,
#              so it can never reach the handler, a signal, or a crash exit.
#   Typical caller shape:
#     lock_acquire production deploy "deploy tag=abc"   # capture the token
#     lock_mark_for_auto_release production deploy "$TOKEN"
#     lock_install_exit_trap                            # install LAST
#     # ... do the work; any exit path (success, error, Ctrl-C) releases it
#
# Exit / return codes (same meaning everywhere — callers can branch on them):
#   LOCK_RC_OK=0       acquired / released / overridden / lock is FREE
#   LOCK_RC_HELD=1      lock is HELD (status), or acquire found it already held
#                       (holder is named on stdout/stderr either way)
#   LOCK_RC_UNKNOWN=2   could NOT be determined (network, access-denied, bad
#                       input, CLI too old, bucket missing, jq missing, an
#                       unparseable/zero-byte lock body...). NEVER treated
#                       as acquired and NEVER treated as free (NFR2,
#                       fail-closed) — lock_require_free refuses on this
#                       exactly like on HELD.
#   LOCK_RC_REFUSED=3  release/override refused: not the holder, lock already
#                       free, override missing --reason/--confirm, or (FR30/
#                       NFR4) override's own audit report could not be
#                       written — an unwritable report ALWAYS aborts the
#                       delete, it never proceeds silently.
#
# Lock object: s3://<project>-<env>-system/locks/<name>.json
#   {"name":..,"actor":..,"operation":..,"host":..,"acquired_at":<UTC ISO8601>,"token":..}
#   Bucket verified against providers/aws/modules/storage/main.tf:
#   `bucket = "${var.naming_prefix}-system"` (origin/main) — the SAME bucket
#   mongo-backup.sh/power-data.sh already write operational state to
#   (providers/aws/cloud-init/init.sh.tftpl, providers/aws/scripts/power-data.sh).
#   No Terraform was added by this story.
#
# Env vars (same discovery convention as power.sh/power-data.sh — these are
# the ONLY names this library reads from the environment; everything it
# computes from them is kept in `_LOCK_`-prefixed variables, never in bare
# `PROJECT`/`REGION`/`SYSTEM_BUCKET`, so sourcing this file can never clobber
# a caller's own same-named globals — see lock_env_defaults):
#   AXIOME_PROJECT        default: axiome
#   AWS_REGION            default: eu-west-3
#   AXIOME_SYSTEM_BUCKET  default: ${AXIOME_PROJECT}-<env>-system
#   LOCK_ACTOR            default: `aws sts get-caller-identity` ARN, else $USER
#   LOCK_RUN_ID           default: $GITHUB_RUN_ID, else $$
#   LOCK_HOST             default: `hostname`
#
# Atomicity / AWS CLI version — SOURCED from the official aws-cli v2
# CHANGELOG (https://github.com/aws/aws-cli/blob/v2/CHANGELOG.rst), not
# guessed:
#   - `acquire`'s atomic create (`put-object --if-none-match '*'`) needs
#     "conditional writes for PutObject" — introduced in aws-cli **2.17.34**.
#     Below that, put-object does not recognise the flag and ERRORS OUT
#     rather than silently overwriting (it never reaches S3 without the
#     flag) — but this script ALSO pre-checks the CLI version and refuses
#     with a clear message before attempting the call, so the failure mode
#     is legible rather than a raw CLI parse error. If the version cannot be
#     determined at all, acquire prints a WARNING and proceeds (the flag
#     itself is still the safety net: an old CLI that gets past the warning
#     still cannot silently overwrite — it will hit the "unsupported option"
#     branch below and FAIL, never fall back to an unconditional create).
#   - `release`'s conditional delete (`delete-object --if-match <etag>`)
#     needs "conditional deletes for DeleteObject" — introduced in aws-cli
#     **2.22.3** (newer than the put-object capability above). There is no
#     separate hard preflight for this one: release always ATTEMPTS the
#     conditional delete and, only if the CLI rejects the option ("Unknown
#     options"), WARNS and falls back to an unconditional delete. Documented
#     race window in that fallback case only: between the read (token
#     compared in-process) and the unconditional delete, another actor's
#     override or a re-acquire-after-crash could replace the object, and the
#     unconditional delete would remove THAT object instead of the one
#     verified. On a CLI new enough for --if-match this window does not
#     exist. The same WARN-and-fall-back-with-the-documented-window applies
#     when the ETag simply could not be read from the get-object call at all
#     (metadata parse failure) — it is never a silent fallback.
#
# Read path (single round trip, no separate head-object): `release`/
# `status`/`override` all read the lock through ONE `aws s3api get-object
# --bucket B --key K <tmpfile>` call. The AWS CLI writes the OBJECT BODY to
# <tmpfile> and prints a METADATA JSON document (including ETag) to stdout
# — the two are never the same stream, and `-`/`/dev/stdout` as the outfile
# does not give you parseable JSON back. The body is read from <tmpfile>
# (created via `mktemp`, removed on every path — success, free, or error)
# and the ETag is parsed from the SAME call's stdout metadata, closing the
# get→head→delete window a separate head-object call would leave open. An
# empty or non-JSON body is NEVER read as "held by an empty actor" — it maps
# to UNKNOWN with a clear message (NFR2). The get-object call passes
# `--output json` EXPLICITLY — the metadata stdout is parsed with jq, and a
# caller/CI runner with `AWS_DEFAULT_OUTPUT=text` (or yaml) would otherwise
# silently change the format, make the ETag parse come back empty, and take
# the documented-but-meant-to-be-rare WARN-and-fall-back-unconditional path
# on every release/override instead of the conditional one. Every other aws
# call either does not parse stdout as structured data at all (acquire's
# put-object, the delete-object calls — their failure text is matched as a
# plain substring, which --output does not affect) or already sets its own
# explicit `--output text` (`_lock_actor`'s get-caller-identity).
#
# FR29 — the data-tier lock is removed only after the data tier is verified
# available again, so a crash between park and verified-unpark must leave it
# held. `lock_mark_for_auto_release` enforces this by REFUSING to register
# name=data-tier at all — it can therefore never appear in `lock_release_held`
# and can never be released by any exit/signal path. Callers must call
# `lock_release` explicitly for data-tier, after their own availability
# check, never from a trap/finally.
#
# No TTL / auto-steal (EC7): a stale lock is only ever surfaced (status: age
# + owner) and removed by the explicit, reported `override` command.
# NOTE: `set -euo pipefail` is applied only when this file is EXECUTED
# directly (see the main guard at the bottom), never when it is sourced —
# changing the caller's shell options would itself be a side effect at
# source time, which the library contract above forbids. Every internal
# failure path below is an explicit `||`/`if` check for exactly this
# reason, so the script's own behaviour does not depend on -e being set.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/report.sh
. "${SCRIPT_DIR}/lib/report.sh"

readonly LOCK_RC_OK=0
readonly LOCK_RC_HELD=1
readonly LOCK_RC_UNKNOWN=2
readonly LOCK_RC_REFUSED=3
readonly LOCK_MIN_AWS_CLI_PUT="2.17.34"
readonly LOCK_MIN_AWS_CLI_DELETE="2.22.3"
readonly LOCK_NAMES="deploy data-tier apply"

# --- env / naming (mirrors providers/aws/scripts/power-data.sh) --------------
# Sets ONLY `_LOCK_`-prefixed globals — never bare PROJECT/REGION/
# SYSTEM_BUCKET, which power.sh/power-data.sh use as their OWN globals.
# Sourcing this file and calling a lock function must never silently
# overwrite a caller's same-named variable (see the header note above).
lock_env_defaults() {
  local env="$1"
  case "$env" in
    dev|staging|production) ;;
    *) echo "ERROR: unknown environment '${env}'. Valid: dev|staging|production" >&2; return "$LOCK_RC_UNKNOWN" ;;
  esac
  _LOCK_PROJECT="${AXIOME_PROJECT:-axiome}"
  _LOCK_REGION="${AWS_REGION:-eu-west-3}"
  _LOCK_SYSTEM_BUCKET="${AXIOME_SYSTEM_BUCKET:-${_LOCK_PROJECT}-${env}-system}"
}

lock_validate_name() {
  case "$1" in
    deploy|data-tier|apply) return 0 ;;
    *) echo "ERROR: unknown lock name '$1'. Valid: deploy|data-tier|apply" >&2; return "$LOCK_RC_UNKNOWN" ;;
  esac
}

lock_key() { printf 'locks/%s.json' "$1"; }

# --- small pure/IO helpers -----------------------------------------------------
# Never `exit` — a sourced caller must only ever see a `return`.
_lock_require_jq() {
  command -v jq >/dev/null 2>&1 && return 0
  echo "ERROR: jq is required (apt/brew install jq)." >&2
  return 1
}

_lock_actor() {
  if [ -n "${LOCK_ACTOR:-}" ]; then printf '%s' "${LOCK_ACTOR}"; return 0; fi
  aws sts get-caller-identity --region "${_LOCK_REGION}" --query Arn --output text 2>/dev/null || printf '%s' "${USER:-unknown}"
}

_lock_host_id() {
  local run="${LOCK_RUN_ID:-${GITHUB_RUN_ID:-$$}}"
  local host="${LOCK_HOST:-$(hostname 2>/dev/null || echo unknown)}"
  printf '%s-%s' "${host}" "${run}"
}

_lock_token() { printf '%s-%s-%s%s' "$(date -u +%s%N)" "$$" "${RANDOM}" "${RANDOM}"; }

_lock_now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

_lock_age_seconds() {
  local iso="$1" acquired_epoch now
  [ -n "$iso" ] || { echo -1; return 0; }
  acquired_epoch="$(date -u -d "${iso}" +%s 2>/dev/null || echo "")"
  [ -n "$acquired_epoch" ] || { echo -1; return 0; }
  now="$(date -u +%s)"
  echo $(( now - acquired_epoch ))
}

# --- AWS CLI version preflight (acquire only; see header for why there is
# no equivalent hard gate for the conditional DELETE used by release) -------
_lock_version_at_least() {
  local maj="$1" min="$2" pat="$3" tmaj="$4" tmin="$5" tpat="$6"
  [ "$maj" -gt "$tmaj" ] && return 0
  [ "$maj" -lt "$tmaj" ] && return 1
  [ "$min" -gt "$tmin" ] && return 0
  [ "$min" -lt "$tmin" ] && return 1
  [ "$pat" -ge "$tpat" ]
}

_lock_cli_version_warn() {
  local ver
  ver="$(aws --version 2>&1 || true)"
  if [[ ! "$ver" =~ aws-cli/([0-9]+)\.([0-9]+)\.([0-9]+) ]]; then
    echo "WARNING: could not determine aws CLI version; lock.sh acquire needs >= ${LOCK_MIN_AWS_CLI_PUT} for atomic '--if-none-match' creation." >&2
    return 0
  fi
  _lock_version_at_least "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" 2 17 34 && return 0
  echo "ERROR: aws CLI ${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.${BASH_REMATCH[3]} is older than the minimum ${LOCK_MIN_AWS_CLI_PUT} required for atomic lock creation (conditional writes). Upgrade the CLI." >&2
  return 1
}

# --- raw aws s3api calls (argv kept deterministic for stub matching) ----------
# Disables -e only around the one call whose non-zero exit is expected/
# handled, then restores whatever -e state the CALLER had (never force it
# ON) — forcing it on would leak into a sourced caller that never asked for
# -e (see the library-contract note at the top of this file).
_lock_was_errexit() { case "$-" in *e*) echo 1 ;; *) echo 0 ;; esac; }

_aws_run() {
  local was_e; was_e="$(_lock_was_errexit)"
  set +e
  _AWS_OUT="$("$@" 2>&1)"
  _AWS_RC=$?
  [ "${was_e}" = "1" ] && set -e
  return 0
}

_lock_put_object() {
  local bucket="$1" key="$2" body="$3" was_e
  was_e="$(_lock_was_errexit)"
  set +e
  _AWS_OUT="$(printf '%s' "${body}" | aws s3api put-object --region "${_LOCK_REGION}" --bucket "${bucket}" --key "${key}" --body /dev/stdin --if-none-match '*' --content-type application/json 2>&1)"
  _AWS_RC=$?
  [ "${was_e}" = "1" ] && set -e
  return 0
}

_lock_delete_object() {
  local bucket="$1" key="$2" etag="${3:-}"
  if [ -n "$etag" ]; then
    _aws_run aws s3api delete-object --region "${_LOCK_REGION}" --bucket "${bucket}" --key "${key}" --if-match "${etag}"
  else
    _aws_run aws s3api delete-object --region "${_LOCK_REGION}" --bucket "${bucket}" --key "${key}"
  fi
}

# --- response classification ---------------------------------------------------
_lock_is_precondition_failed() { [[ "$1" == *"PreconditionFailed"* || "$1" == *"412"* ]]; }
_lock_is_not_found()           { [[ "$1" == *"NoSuchKey"* || "$1" == *"404"* || "$1" == *"Not Found"* ]]; }
_lock_is_unsupported_option()  { [[ "$1" == *"Unknown options"* ]]; }

# --- lock JSON body ------------------------------------------------------------
_lock_build_body() { # name actor operation host now token
  _lock_require_jq || return 1
  jq -n --arg n "$1" --arg a "$2" --arg o "$3" --arg h "$4" --arg t "$5" --arg k "$6" \
    '{name:$n, actor:$a, operation:$o, host:$h, acquired_at:$t, token:$k}'
}

_lock_parse_body() {
  local json="$1"
  _LOCK_ACTOR="$(printf '%s' "${json}" | jq -r '.actor // "unknown"')"
  _LOCK_OPERATION="$(printf '%s' "${json}" | jq -r '.operation // "unknown"')"
  _LOCK_AT="$(printf '%s' "${json}" | jq -r '.acquired_at // ""')"
  _LOCK_HOST="$(printf '%s' "${json}" | jq -r '.host // "unknown"')"
  _LOCK_TOKEN="$(printf '%s' "${json}" | jq -r '.token // ""')"
}

# Reads+validates the lock BODY from the tmpfile written by the get-object
# call. A zero-byte or non-JSON body is a parse failure (rc 1), never a
# silent "held by blank" (NFR2) — the caller maps that to UNKNOWN.
_lock_parse_body_file() {
  local file="$1" json
  _lock_require_jq || return 1
  [ -s "$file" ] || return 1
  json="$(cat "$file")"
  printf '%s' "${json}" | jq -e . >/dev/null 2>&1 || return 1
  _lock_parse_body "${json}"
  return 0
}

# Reads the ETag from the get-object call's own METADATA JSON (its stdout,
# never the body file) — this is what lets release skip the separate
# head-object call entirely and closes the get->head->delete window.
_lock_parse_metadata_etag() {
  _LOCK_ETAG=""
  _lock_require_jq >/dev/null 2>&1 || return 0
  _LOCK_ETAG="$(printf '%s' "$1" | jq -r '.ETag // ""' 2>/dev/null)"
}

# --- read the current lock state (held/free/unknown) --------------------------
_lock_fetch() {
  local env="$1" name="$2" key tmpfile
  lock_env_defaults "$env" || { _LOCK_STATE="unknown"; _LOCK_ERR="bad environment"; return 1; }
  key="$(lock_key "$name")"
  tmpfile="$(mktemp 2>/dev/null)" || { _LOCK_STATE="unknown"; _LOCK_ERR="could not create a temp file to read the lock body"; return 1; }
  _aws_run aws s3api get-object --region "${_LOCK_REGION}" --output json --bucket "${_LOCK_SYSTEM_BUCKET}" --key "${key}" "${tmpfile}"
  if [ "${_AWS_RC}" -ne 0 ]; then
    rm -f "${tmpfile}"
    if _lock_is_not_found "${_AWS_OUT}"; then _LOCK_STATE="free"; return 0; fi
    _LOCK_STATE="unknown"; _LOCK_ERR="${_AWS_OUT}"
    return 1
  fi
  _lock_parse_metadata_etag "${_AWS_OUT}"
  if ! _lock_parse_body_file "${tmpfile}"; then
    rm -f "${tmpfile}"
    _LOCK_STATE="unknown"; _LOCK_ERR="lock object at ${key} has an empty or non-JSON body"
    return 1
  fi
  rm -f "${tmpfile}"
  _LOCK_STATE="held"
  return 0
}

_lock_print_status() {
  local env="$1" name="$2"
  if ! _lock_fetch "$env" "$name"; then
    echo "${name}: UNKNOWN (${_LOCK_ERR})"
    return "${LOCK_RC_UNKNOWN}"
  fi
  if [ "${_LOCK_STATE}" = "free" ]; then
    echo "${name}: FREE"
    return "${LOCK_RC_OK}"
  fi
  echo "${name}: HELD by ${_LOCK_ACTOR} running ${_LOCK_OPERATION} since ${_LOCK_AT} (age $(_lock_age_seconds "${_LOCK_AT}")s) host=${_LOCK_HOST}"
  return "${LOCK_RC_HELD}"
}

# --- public: status -------------------------------------------------------------
lock_status() {
  local env="$1" name="${2:-}" n rc worst="${LOCK_RC_OK}"
  local names=()
  if [ -n "$name" ]; then names=("$name"); else read -r -a names <<< "${LOCK_NAMES}"; fi
  for n in "${names[@]}"; do
    lock_validate_name "$n" || return "${LOCK_RC_UNKNOWN}"
    _lock_print_status "$env" "$n"; rc=$?
    [ "$rc" -gt "$worst" ] && worst="$rc"
  done
  return "$worst"
}

# --- public: acquire -------------------------------------------------------------
lock_acquire() {
  local env="$1" name="$2" operation="$3"
  lock_validate_name "$name" || return "${LOCK_RC_UNKNOWN}"
  lock_env_defaults "$env" || return "${LOCK_RC_UNKNOWN}"
  _lock_cli_version_warn || return "${LOCK_RC_UNKNOWN}"
  local token actor host now key body
  token="$(_lock_token)"; actor="$(_lock_actor)"; host="$(_lock_host_id)"; now="$(_lock_now_iso)"
  key="$(lock_key "$name")"
  body="$(_lock_build_body "$name" "$actor" "$operation" "$host" "$now" "$token")" || {
    echo "ERROR: could not build the lock body (jq missing or failed) — lock '${name}' was NOT acquired." >&2
    return "${LOCK_RC_UNKNOWN}"
  }
  _lock_put_object "${_LOCK_SYSTEM_BUCKET}" "${key}" "${body}"
  if [ "${_AWS_RC}" -eq 0 ]; then
    echo "ACQUIRED ${name} token=${token} actor=${actor} at=${now}"
    return "${LOCK_RC_OK}"
  fi
  if _lock_is_precondition_failed "${_AWS_OUT}"; then
    _lock_print_status "$env" "$name" >&2
    return "${LOCK_RC_HELD}"
  fi
  if _lock_is_unsupported_option "${_AWS_OUT}"; then
    echo "ERROR: this AWS CLI does not support conditional writes (--if-none-match) — upgrade to at least ${LOCK_MIN_AWS_CLI_PUT}. Refusing rather than risk an unconditional overwrite." >&2
    return "${LOCK_RC_UNKNOWN}"
  fi
  echo "ERROR: could not acquire lock '${name}': ${_AWS_OUT}" >&2
  return "${LOCK_RC_UNKNOWN}"
}

# --- public: release / override shared delete ------------------------------------
# mode=conditional: attempt `--if-match <etag>` first (release's contract —
#   only remove the exact version just verified to belong to the caller);
#   WARN and fall back to an unconditional delete if the etag is missing or
#   the CLI rejects the option (documented race window, see header).
# mode=force: always unconditional (override's contract — it is explicitly
#   the one way to remove a lock you do NOT hold, so there is nothing to
#   condition on).
_lock_delete_lock() { # env name etag verb mode
  local env="$1" name="$2" etag="$3" verb="${4:-RELEASED}" mode="${5:-conditional}" key
  lock_env_defaults "$env" || return "${LOCK_RC_UNKNOWN}"
  key="$(lock_key "$name")"
  if [ "$mode" = "force" ]; then
    _lock_delete_object "${_LOCK_SYSTEM_BUCKET}" "${key}" ""
  elif [ -z "$etag" ]; then
    echo "WARNING: no ETag available for '${name}' — the delete cannot be made conditional; proceeding with an unconditional delete (a lock replaced in this instant would be removed anyway, see header)." >&2
    _lock_delete_object "${_LOCK_SYSTEM_BUCKET}" "${key}" ""
  else
    _lock_delete_object "${_LOCK_SYSTEM_BUCKET}" "${key}" "${etag}"
    if [ "${_AWS_RC}" -ne 0 ] && _lock_is_unsupported_option "${_AWS_OUT}"; then
      echo "WARNING: this AWS CLI does not support conditional deletes (--if-match, needs >= ${LOCK_MIN_AWS_CLI_DELETE}) — falling back to an unconditional delete; a lock replaced between read and delete in this window would be removed anyway (see header)." >&2
      _lock_delete_object "${_LOCK_SYSTEM_BUCKET}" "${key}" ""
    fi
  fi
  if [ "${_AWS_RC}" -eq 0 ]; then echo "${verb} ${name}"; return "${LOCK_RC_OK}"; fi
  echo "ERROR: could not delete lock '${name}': ${_AWS_OUT}" >&2
  return "${LOCK_RC_UNKNOWN}"
}

lock_release() {
  local env="$1" name="$2" token="$3"
  lock_validate_name "$name" || return "${LOCK_RC_UNKNOWN}"
  if ! _lock_fetch "$env" "$name"; then
    echo "ERROR: cannot release '${name}': lock state undetermined (${_LOCK_ERR})" >&2
    return "${LOCK_RC_UNKNOWN}"
  fi
  if [ "${_LOCK_STATE}" = "free" ]; then
    echo "ERROR: cannot release '${name}': lock is not held" >&2
    return "${LOCK_RC_REFUSED}"
  fi
  if [ "${_LOCK_TOKEN}" != "${token}" ]; then
    echo "ERROR: cannot release '${name}': held by ${_LOCK_ACTOR} (${_LOCK_OPERATION}); caller's token does not match" >&2
    return "${LOCK_RC_REFUSED}"
  fi
  _lock_delete_lock "$env" "$name" "${_LOCK_ETAG}" "RELEASED" "conditional"
}

# --- public: override -------------------------------------------------------------
lock_override() {
  local env="$1" name="$2" reason="$3" confirm="$4"
  lock_validate_name "$name" || return "${LOCK_RC_UNKNOWN}"
  [ -n "$reason" ] || { echo "ERROR: override requires --reason <text>" >&2; return "${LOCK_RC_REFUSED}"; }
  [ "$confirm" = "yes" ] || { echo "ERROR: override requires --confirm" >&2; return "${LOCK_RC_REFUSED}"; }
  if ! _lock_fetch "$env" "$name"; then
    echo "ERROR: cannot override '${name}': state undetermined (${_LOCK_ERR})" >&2
    return "${LOCK_RC_UNKNOWN}"
  fi
  if [ "${_LOCK_STATE}" = "free" ]; then
    echo "ERROR: cannot override '${name}': lock is not held" >&2
    return "${LOCK_RC_REFUSED}"
  fi
  _lock_override_report "$env" "$name" "$reason" || return "${LOCK_RC_REFUSED}"
  _lock_delete_lock "$env" "$name" "" "OVERRIDDEN" "force"
}

# Every step here is CHECKED (FR30/NFR4): if the audit report cannot be
# written — e.g. report.sh's secret-shaped-text guard refuses the reason —
# the override is ABORTED with a plain message and the lock is NEVER
# deleted. A silently-swallowed report failure would delete the lock with
# no record of who/why, which is exactly what FR30 forbids.
#
# NOTE (not this script's bug, avoided from this side anyway): report.sh's
# report_init creates its temp buffer (`mktemp`) BEFORE report_override's
# own secret-shaped-text check runs, so if report_init succeeds and
# report_override is the one that refuses, that buffer is never moved or
# removed — a leaked tempfile. report.sh exposes no cleanup for it and is
# out of this story's ownership boundary. The pre-check below (reusing
# report.sh's own `_report_is_secret`, already in scope from sourcing it)
# avoids ever reaching report_init in the one case that actually triggers
# this: a secret-shaped --reason. report_override's own check is kept as
# defense in depth.
_lock_override_report() {
  local env="$1" name="$2" reason="$3" age
  age="$(_lock_age_seconds "${_LOCK_AT}")"
  if _report_is_secret "$reason"; then
    echo "ERROR: override of '${name}' ABORTED — the given --reason resembles a secret-shaped string (e.g. contains 'password=' or similar). Rephrase --reason and retry. The lock was NOT deleted." >&2
    return 1
  fi
  report_init "${env}" "lock-override" "lock=${name}" || {
    echo "ERROR: override of '${name}' ABORTED — could not write the audit report (report_init failed). The lock was NOT deleted." >&2
    return 1
  }
  report_override "${name}" "previous holder ${_LOCK_ACTOR} running operation ${_LOCK_OPERATION}, age ${age} seconds, reason: ${reason}" || {
    echo "ERROR: override of '${name}' ABORTED — the audit report refused this reason text (it resembles a secret-shaped string, e.g. contains 'password=' or similar). Rephrase --reason and retry. The lock was NOT deleted." >&2
    return 1
  }
  report_finish "overridden" || {
    echo "ERROR: override of '${name}' ABORTED — could not finalise the audit report. The lock was NOT deleted." >&2
    return 1
  }
  return 0
}

# --- library helpers for callers (AXI-1951/AXI-1954) --------------------------
lock_require_free() {
  local env="$1" name="$2" rc
  lock_status "$env" "$name" >/dev/null
  rc=$?
  [ "$rc" -eq "${LOCK_RC_OK}" ] && return 0
  echo "ERROR: lock '${name}' is not free (rc=${rc}) — refusing to proceed." >&2
  return "$rc"
}

# lock_acquire_exclusive <env> <name> <operation> <other_name> [<other_name> ...]
# (AXI-1967, FR42/FR43, AC34/AC35) — "acquire mine, THEN check the others"
# in one call, for every caller that must never check-then-acquire (a check
# that passes and an acquire a moment later leaves a window where two
# operations can both see the others free and both proceed; acquiring
# first and only then checking means two operations racing this way can
# both refuse, but never both proceed).
#
# On success: behaves exactly like a plain `lock_acquire` — prints the same
# `ACQUIRED <name> token=<token> actor=<actor> at=<iso>` line to stdout (so
# an existing caller's `sed -n 's/.*token=\([^ ]*\).*/\1/p'` parsing is
# unchanged) and returns LOCK_RC_OK. <name> itself is NOT marked for
# auto-release here — that remains the caller's own choice
# (lock_mark_for_auto_release / lock_install_exit_trap), exactly as for a
# plain lock_acquire.
#
# On failure to acquire <name> itself: returns lock_acquire's own rc
# unchanged; nothing was acquired, so there is nothing to release.
#
# On success acquiring <name> but ANY <other_name> is not free (held or
# UNKNOWN): releases <name> (this call's own, just-acquired token — never
# a lock this call did not itself take) and returns that other lock's rc,
# having already named which lock blocked it on stderr.
lock_acquire_exclusive() {
  local env="$1" name="$2" operation="$3"; shift 3
  local acquire_out rc token other other_rc
  acquire_out="$(lock_acquire "$env" "$name" "$operation")"
  rc=$?
  [ "$rc" -eq "${LOCK_RC_OK}" ] || return "$rc"
  printf '%s\n' "${acquire_out}"
  token="$(printf '%s\n' "${acquire_out}" | sed -n 's/.*token=\([^ ]*\).*/\1/p')"
  for other in "$@"; do
    # Capture lock_require_free's OWN rc BEFORE any negation — `if !
    # lock_require_free ...; then other_rc=$?; fi` is a trap: `$?` inside
    # that branch reflects the `!`-negated boolean (always 0 on entry to
    # `then`), never lock_require_free's real exit code, so a held lock
    # would always be reported back as rc=0 (success) here.
    lock_require_free "$env" "$other"
    other_rc=$?
    if [ "$other_rc" -ne "${LOCK_RC_OK}" ]; then
      echo "ERROR: acquired '${name}' but '${other}' is not free — releasing '${name}' and refusing (FR43)." >&2
      lock_release "$env" "$name" "${token}" >&2
      return "$other_rc"
    fi
  done
  return "${LOCK_RC_OK}"
}

# --- auto-release (replaces the earlier blind-trap `lock_release_on_exit`) ------
# See the header's "Auto-release" section for the full contract.
_LOCK_AUTO_ENV=(); _LOCK_AUTO_NAME=(); _LOCK_AUTO_TOKEN=()

lock_mark_for_auto_release() { # env name token
  local env="$1" name="$2" token="$3"
  if [ "$name" = "data-tier" ]; then
    echo "ERROR: lock_mark_for_auto_release refuses 'data-tier' (FR29) — the data-tier lock must be removed only after the data tier is verified available again, never automatically on exit/crash/signal. Call lock_release explicitly after verification." >&2
    return "${LOCK_RC_REFUSED}"
  fi
  _LOCK_AUTO_ENV+=("$env"); _LOCK_AUTO_NAME+=("$name"); _LOCK_AUTO_TOKEN+=("$token")
}

# Idempotent: a second call (or a first call with nothing registered) is a
# no-op, rc 0 — the registry is cleared after releasing, so there is never
# a second delete attempt for the same lock.
lock_release_held() {
  local i n="${#_LOCK_AUTO_NAME[@]}" rc=0
  [ "$n" -gt 0 ] || return 0
  for ((i = 0; i < n; i++)); do
    lock_release "${_LOCK_AUTO_ENV[$i]}" "${_LOCK_AUTO_NAME[$i]}" "${_LOCK_AUTO_TOKEN[$i]}" || rc=$?
  done
  _LOCK_AUTO_ENV=(); _LOCK_AUTO_NAME=(); _LOCK_AUTO_TOKEN=()
  return "$rc"
}

# Quote-proof by construction: NEVER text-rewrites `trap -p EXIT`'s output
# and never re-embeds a caller's trap command inside another trap string
# (that is exactly the defect class a sed-stripped `trap -p` reconstruction
# has — any single quote, `$VAR`, newline or backslash in the caller's
# command breaks the reconstructed string). Instead the WHOLE, already
# correctly quoted `trap -p EXIT` line is captured verbatim into
# `_LOCK_PREV_EXIT_TRAP`, and the EXIT trap is always the one fixed,
# untouched literal `_lock_exit_trap_handler` — no untrusted text is ever
# part of the trap command itself.
_LOCK_PREV_EXIT_TRAP=""

# Restores+runs the previously captured EXIT trap command, if any. `trap -p`
# output has the shape `trap -- '<command>' EXIT` with the command already
# shell-quoted; `eval "set -- $saved"` lets the shell do that unquoting for
# us (the same mechanism `trap -p`'s output is designed to be fed back
# into), landing the original command text in $3 — never parsed by hand.
# shellcheck disable=SC2120 # $1../$3 below come from this function's OWN
# `set --`, never from a caller-supplied argument.
_lock_run_saved_exit_trap() {
  [ -n "${_LOCK_PREV_EXIT_TRAP}" ] || return 0
  local saved="${_LOCK_PREV_EXIT_TRAP}" cmd
  eval "set -- ${saved}"
  cmd="$3"
  eval "${cmd}"
}

# The one fixed EXIT trap command every `lock_install_exit_trap` call
# installs. Captures the ORIGINAL exit status ($? at entry, before
# lock_release_held or anything else can change it) and re-asserts it at
# the end via `exit`, UNLESS the restored caller trap itself calls `exit`
# first (its own explicit exit wins, matching what would have happened had
# it run alone).
_lock_exit_trap_handler() {
  local rc=$?
  lock_release_held
  _lock_run_saved_exit_trap
  exit "${rc}"
}

# Installs `_lock_exit_trap_handler` as the EXIT trap, capturing whatever
# EXIT trap already exists so the handler can run it afterward (chaining,
# never overwriting). A SECOND call detects its own handler already
# installed and leaves `_LOCK_PREV_EXIT_TRAP` as-is — it never re-wraps
# itself (no self-chaining, no double release). Also routes INT/TERM
# through `exit` so a Ctrl-C/SIGTERM still runs the EXIT trap instead of
# leaking the lock (bash does not run an EXIT trap on a bare signal
# otherwise) — see the header's CAVEATS for what this replaces.
lock_install_exit_trap() {
  local current
  current="$(trap -p EXIT)"
  case "${current}" in
    *_lock_exit_trap_handler*) ;;
    *) _LOCK_PREV_EXIT_TRAP="${current}" ;;
  esac
  trap '_lock_exit_trap_handler' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
}

# --- CLI dispatch ----------------------------------------------------------------
_lock_usage() {
  sed -n '34,37p' "${BASH_SOURCE[0]}" >&2
  exit "${LOCK_RC_UNKNOWN}"
}

_lock_cli_acquire() {
  local env="$1"; shift
  local name="${1:-}"; shift || true
  local operation=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --operation) operation="$2"; shift 2 ;;
      *) echo "ERROR: unknown argument '$1'" >&2; exit "${LOCK_RC_UNKNOWN}" ;;
    esac
  done
  [ -n "$name" ] || { echo "ERROR: acquire requires <name>" >&2; exit "${LOCK_RC_UNKNOWN}"; }
  [ -n "$operation" ] || { echo "ERROR: acquire requires --operation <text>" >&2; exit "${LOCK_RC_UNKNOWN}"; }
  lock_acquire "$env" "$name" "$operation"
}

_lock_cli_release() {
  local env="$1"; shift
  local name="${1:-}"; shift || true
  local token=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --token) token="$2"; shift 2 ;;
      *) echo "ERROR: unknown argument '$1'" >&2; exit "${LOCK_RC_UNKNOWN}" ;;
    esac
  done
  [ -n "$name" ] || { echo "ERROR: release requires <name>" >&2; exit "${LOCK_RC_UNKNOWN}"; }
  [ -n "$token" ] || { echo "ERROR: release requires --token <token>" >&2; exit "${LOCK_RC_UNKNOWN}"; }
  lock_release "$env" "$name" "$token"
}

_lock_cli_status() {
  local env="$1"; shift
  local name="${1:-}"
  lock_status "$env" "$name"
}

_lock_cli_override() {
  local env="$1"; shift
  local name="${1:-}"; shift || true
  local reason="" confirm="no"
  while [ $# -gt 0 ]; do
    case "$1" in
      --reason) reason="$2"; shift 2 ;;
      --confirm) confirm="yes"; shift ;;
      *) echo "ERROR: unknown argument '$1'" >&2; exit "${LOCK_RC_UNKNOWN}" ;;
    esac
  done
  [ -n "$name" ] || { echo "ERROR: override requires <name>" >&2; exit "${LOCK_RC_UNKNOWN}"; }
  lock_override "$env" "$name" "$reason" "$confirm"
}

main() {
  [ $# -ge 2 ] || _lock_usage
  local env="$1" cmd="$2"; shift 2
  case "$cmd" in
    acquire)  _lock_cli_acquire "$env" "$@" ;;
    release)  _lock_cli_release "$env" "$@" ;;
    status)   _lock_cli_status "$env" "$@" ;;
    override) _lock_cli_override "$env" "$@" ;;
    *) _lock_usage ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  set -euo pipefail
  main "$@"
fi
