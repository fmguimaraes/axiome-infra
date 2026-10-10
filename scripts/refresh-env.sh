#!/usr/bin/env bash
# scripts/refresh-env.sh — AXI-1950 (epic AXI-1944 decision 5, FR12/EC5/EC6/
# AC10). Regenerates <env-file> from SSM Parameter Store atomically
# (temp file in the same directory, chmod 600, rename), preserving the
# locally recorded image-tag + identification keys (decision 5:
# BACKEND_IMAGE_TAG, BIOCOMPUTE_IMAGE_TAG, FRONTEND_IMAGE_TAG, ENVIRONMENT,
# PROJECT_NAME, ECR_REGISTRY, FQDN) whatever SSM currently holds for them —
# SSM may carry a stale image tag; reverting to it would silently redeploy
# an old version (EC5). Usage: refresh-env.sh <env-file>, with
# SSM_PARAMETER_PREFIX set in the environment.
#
# Fails SAFE, never partial: if SSM cannot be read, or any key that is not
# in the preserved set comes back missing/empty, <env-file> is left byte-
# identical, a warning is logged, and this script exits non-zero so the
# caller (scripts/boot.sh) can treat it as "continue with what's there"
# (EC6). NFR3: never prints a parameter value — only key names, in the
# warning paths only.
#
# AXI-1969 (FR50/AC43): the original parse requested `--output text` and
# split "<path>\t<value>" on a tab with awk. A value containing a literal
# newline, carriage return, or tab corrupts that shape (same weakness as
# the cloud-init bootstrap's own SSM parse in providers/aws/cloud-init/
# init.sh.tftpl, which this story does not touch). This script now
# requests `--output json` and parses with `jq`, which JSON-escapes
# control characters, so one of these inside a value can be detected
# reliably instead of silently corrupting <env-file>. `jq` is installed on
# the box by cloud-init (providers/aws/cloud-init/init.sh.tftpl's package
# list) and is already a hard dependency of several sibling scripts
# (scripts/lock.sh, scripts/ssm-exec.sh, providers/aws/scripts/power.sh).
#
# Exit codes:
#   0  refreshed
#   1  usage error, or `jq` is not available on this box
#   2  SSM unreachable or returned no parameters — existing <env-file> kept
#   3  a required (non-preserved) key came back missing/empty — kept
#   4  a parameter value contains a newline, carriage return, or tab —
#       refused, kept; the parameter is named on stderr, its value is
#       never printed
set -uo pipefail
# No `set -e`: an SSM failure must fall through to "keep existing file",
# not abort before that decision is made.

PRESERVE_KEYS="BACKEND_IMAGE_TAG BIOCOMPUTE_IMAGE_TAG FRONTEND_IMAGE_TAG ENVIRONMENT PROJECT_NAME ECR_REGISTRY FQDN"

usage() { echo "usage: refresh-env.sh <env-file>" >&2; exit 1; }

is_preserved_key() {
  local key="$1" p
  for p in $PRESERVE_KEYS; do
    [ "$key" = "$p" ] && return 0
  done
  return 1
}

read_env_file() {
  grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$1" 2>/dev/null || true
}

fetch_ssm_json() {
  aws ssm get-parameters-by-path \
    --path "$1" --recursive --with-decryption \
    --output json 2>/dev/null
}

# Number of parameters in a get-parameters-by-path JSON response. Always
# prints a plain non-negative integer — 0 for an empty/malformed response —
# so callers never need to guard against a non-numeric comparison.
param_count() {
  local n
  n="$(printf '%s' "$1" | jq -r '(.Parameters // []) | length' 2>/dev/null)"
  case "$n" in
    ''|*[!0-9]*) echo 0 ;;
    *) echo "$n" ;;
  esac
}

# Prints the bare (last-segment) name of the FIRST parameter whose value
# contains a literal newline, carriage return, or tab; prints nothing if
# none do. Never reads .Value into its own output — only .Name.
first_bad_value_name() {
  printf '%s' "$1" | jq -r '
    (.Parameters // [])
    | map(select((.Value | test("\n")) or (.Value | test("\r")) or (.Value | test("\t"))))
    | if length > 0 then (.[0].Name | split("/") | last) else empty end
  ' 2>/dev/null
}

# "KEY=VALUE\n..." for every parameter. Only safe to call after
# first_bad_value_name has confirmed no value contains a newline/tab.
fetch_ssm() {
  printf '%s' "$1" | jq -r '
    (.Parameters // [])[] | (.Name | split("/") | last) + "=" + .Value
  ' 2>/dev/null
}

value_of_key() {
  local key="$1" line
  while IFS= read -r line; do
    case "$line" in
      "${key}="*) printf '%s\n' "${line#*=}"; return 0 ;;
    esac
  done
  return 1
}

all_keys_of() {
  printf '%s\n%s\n' "$1" "$2" | grep -Eo '^[A-Za-z_][A-Za-z0-9_]*' | sort -u
}

# Prints "KEY=VALUE\n..." on stdout; returns non-zero (no partial output
# relied on by the caller) the moment any required key is missing/empty.
compose_new_env() {
  local old="$1" new_ssm="$2" key val
  while IFS= read -r key; do
    [ -z "$key" ] && continue
    if is_preserved_key "$key"; then
      val="$(printf '%s\n' "$old" | value_of_key "$key")" || return 1
    else
      val="$(printf '%s\n' "$new_ssm" | value_of_key "$key")" || return 1
      [ -n "$val" ] || return 1
    fi
    printf '%s=%s\n' "$key" "$val"
  done < <(all_keys_of "$old" "$new_ssm")
}

write_atomically() {
  local env_file="$1" content="$2" tmp
  tmp="$(mktemp "${env_file}.tmp.XXXXXX")"
  trap '[ -f "${tmp:-}" ] && rm -f "${tmp}"' EXIT
  printf '%s\n' "$content" > "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$env_file"
  trap - EXIT
}

main() {
  local env_file="${1:-}" old ssm_json bad_name new_ssm new_content
  [ -n "$env_file" ] || usage
  local prefix="${SSM_PARAMETER_PREFIX:?SSM_PARAMETER_PREFIX env var required}"
  [ -f "$env_file" ] || { echo "ERROR refresh-env: ${env_file} does not exist" >&2; exit 1; }
  command -v jq >/dev/null 2>&1 || { echo "ERROR refresh-env: jq is required (apt/brew install jq)" >&2; exit 1; }

  old="$(read_env_file "$env_file")"
  ssm_json="$(fetch_ssm_json "$prefix")"
  if [ -z "$ssm_json" ] || [ "$(param_count "$ssm_json")" -eq 0 ]; then
    echo "WARN refresh-env: SSM unreachable or empty at ${prefix} — keeping existing ${env_file}" >&2
    exit 2
  fi

  bad_name="$(first_bad_value_name "$ssm_json")"
  if [ -n "$bad_name" ]; then
    echo "WARN refresh-env: SSM parameter '${bad_name}' contains a newline, carriage return or tab — refusing it, keeping existing ${env_file}" >&2
    exit 4
  fi

  new_ssm="$(fetch_ssm "$ssm_json")"
  if [ -z "$new_ssm" ]; then
    echo "WARN refresh-env: SSM unreachable or empty at ${prefix} — keeping existing ${env_file}" >&2
    exit 2
  fi
  if ! new_content="$(compose_new_env "$old" "$new_ssm")"; then
    echo "WARN refresh-env: a required key was missing/empty in the SSM result — keeping existing ${env_file}" >&2
    exit 3
  fi

  write_atomically "$env_file" "$new_content"
  echo "refresh-env: ${env_file} refreshed from ${prefix}"
}

main "$@"
