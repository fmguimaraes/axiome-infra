#!/usr/bin/env bash
# wt-status.sh — list every worktree stack registered on this machine with its
# ports, databases, Redis index, RabbitMQ vhost, and buckets, and whether its
# app stack is currently running.
#
#   --verify   also probe the shared services (Postgres DB present? buckets
#              present?) instead of just showing derived names. Slower.
#   -h|--help  this help
#
# Per-line shellcheck disables below (AXI-1952 — this file was already
# baselined for exactly these findings before this story; not fixable
# without changing shared files this story does not own):
#   SC2154 — every _c_* var is defined only in the dynamically-sourced
#     wt-common.sh ($(...)-computed path); shellcheck cannot follow that
#     without -x, which the shared gate (tests/run-shellcheck.sh,
#     AXI-1945-owned) does not pass. shellcheck only reports each distinct
#     variable once, at its first reference, so the disable sits there.
#   SC2034 — `path`, read from the tab-separated registry row, is an
#     intentionally-unused positional field (can't skip a middle column of
#     `read`).
set -euo pipefail
# shellcheck source=./wt-common.sh
. "$(cd "$(dirname "$0")" && pwd)/wt-common.sh"

VERIFY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --verify) VERIFY=1 ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) die "unknown flag: $1" ;;
  esac; shift
done

need_docker

# --- Shared stack ----------------------------------------------------------
if shared_running; then
  # shellcheck disable=SC2154  # _c_bold/_c_reset/_c_green: see note above set -euo pipefail
  printf '%sShared stack (%s):%s %sUP%s  — postgres:5432 redis:6379 minio:9000/9001 mongodb:27017 rabbitmq:5672/15672\n' \
    "${_c_bold}" "${SHARED_PROJECT}" "${_c_reset}" "${_c_green}" "${_c_reset}"
else
  # shellcheck disable=SC2154  # _c_red: see note above set -euo pipefail
  printf '%sShared stack (%s):%s %sDOWN%s  — run scripts/wt-up.sh (any worktree) to start it\n' \
    "${_c_bold}" "${SHARED_PROJECT}" "${_c_reset}" "${_c_red}" "${_c_reset}"
fi

# --- Worktrees -------------------------------------------------------------
rows="$(wt_registry_list || true)"
if [ -z "${rows}" ]; then
  # shellcheck disable=SC2154  # _c_dim: see note above set -euo pipefail
  printf '\n%sNo worktree stacks registered.%s Run scripts/wt-up.sh in a worktree.\n' "${_c_dim}" "${_c_reset}"
  exit 0
fi

printf '\n%s%-16s %-6s %-7s %-7s %-9s %-9s %-6s %-7s %s%s\n' "${_c_bold}" \
  "SLUG" "STATE" "FRONT" "API" "BIOCMP" "PG/MONGO" "REDIS" "VHOST" "BUCKETS (<slug>-…)" "${_c_reset}"
printf '%s%s%s\n' "${_c_dim}" "$(printf '─%.0s' $(seq 1 100))" "${_c_reset}"

# shellcheck disable=SC2034  # path: intentionally-unused positional field
while IFS=$'\t' read -r slug offset redis_db path; do
  [ -n "${slug}" ] || continue
  wt_derive_vars "${slug}" "${offset}" "${redis_db}"
  if app_running "${slug}"; then state="${_c_green}up${_c_reset}    "; else state="${_c_dim}down${_c_reset}  "; fi

  extra=""
  if [ "${VERIFY}" -eq 1 ] && shared_running; then
    pg_db_exists "${PG_DB}" && dbmark="db✓" || dbmark="db✗"
    if mc_sh "mc ls local/${B_UPLOADS} >/dev/null 2>&1"; then bkmark="buk✓"; else bkmark="buk✗"; fi
    extra="  [${dbmark} ${bkmark}]"
  fi

  printf '%-16s %b %-7s %-7s %-9s %-9s %-6s %-7s %s%s\n' \
    "${slug}" "${state}" \
    "${FRONTEND_PORT}" "${BACKEND_PORT}" "${BIOCOMPUTE_PORT}" \
    "${PG_DB}" "${redis_db}" "${MQ_VHOST}" \
    "uploads/artifacts/system" "${extra}"
done <<EOF
${rows}
EOF

printf '\n%sregistry:%s %s\n' "${_c_dim}" "${_c_reset}" "${REGISTRY_FILE}"
