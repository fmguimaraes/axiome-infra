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

fetch_ssm() {
  aws ssm get-parameters-by-path \
    --path "$1" --recursive --with-decryption \
    --query "Parameters[].[Name,Value]" --output text 2>/dev/null \
    | awk -F'\t' '{n=split($1,p,"/"); printf "%s=%s\n", p[n], $2}'
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
  local env_file="${1:-}" old new_ssm new_content
  [ -n "$env_file" ] || usage
  local prefix="${SSM_PARAMETER_PREFIX:?SSM_PARAMETER_PREFIX env var required}"
  [ -f "$env_file" ] || { echo "ERROR refresh-env: ${env_file} does not exist" >&2; exit 1; }

  old="$(read_env_file "$env_file")"
  new_ssm="$(fetch_ssm "$prefix")"
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
