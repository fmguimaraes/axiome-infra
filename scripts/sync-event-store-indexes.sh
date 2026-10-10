#!/usr/bin/env bash
# sync-event-store-indexes.sh — explicit, opt-in sync of the local event-store
# (MongoDB) indexes for the backend's event-service (AXI-1971, FR56/AC49).
#
# Why this exists: before this story, wt-up.sh ran `prisma db push` for the
# event-service schema (including its @@index declarations) as a side
# effect of every stack start. That was removed (epic AXI-1944 decision:
# "wt-up.sh no longer runs the local event-service Mongo `prisma db push`;
# decide how local Mongo indexes get synced") because a start/up path is
# the wrong place for a schema-sync step to live silently. This script is
# the explicit replacement: it is NEVER called by any start, up, migrate or
# seed path (see tests/sync-event-store-indexes.bats's structural check) —
# an operator (or CI job) runs it by hand, only when they mean to.
#
# It invokes the APPLICATION's OWN index definition rather than duplicating
# the list here: `npx prisma db push` reads the `@@index([...])` directives
# already declared in axiome-back's own
# apps/event-service/src/prisma/schema.prisma (read-only from this repo —
# axiome-infra never edits axiome-back). Prisma diffs that schema against
# the live database and applies only the drift; a no-op re-run is a no-op
# (idempotent). It runs with `--skip-generate` (indexes/schema only, no
# client regen needed for this) and, DELIBERATELY, with NO
# `--accept-data-loss` (or any other data-loss-accepting flag) anywhere on
# its command line (AC49) — if Prisma itself judges a change destructive,
# this command refuses non-interactively (Prisma's own prompt has no TTY to
# answer) rather than silently forcing it through. That refusal is the
# correct, fail-closed outcome for an index-sync command, not a bug to work
# around.
#
# Safety (FR56):
#   - refuses a MongoDB address that is not local (loopback, or the
#     `mongodb` compose-network container alias) — never touches a remote
#     event store;
#   - refuses outright if the connection string is supplied on the command
#     line WITH embedded credentials (`mongodb://user:pass@host/...`) —
#     secrets never belong on argv (ps, shell history);  the normal path
#     reads the URL from the container's own environment (already set by
#     docker-compose.yml) or from a local --env-file, never printing it;
#   - has no flag anywhere that can drop data or drop indexes;
#   - is idempotent — safe to re-run.
#
# Usage:
#   sync-event-store-indexes.sh --compose-project <p> --compose-file <f> \
#     [--env-file <f>] [--service backend] [--mongodb-url <url>]
#
# --mongodb-url is for an operator who wants to validate a URL that is
# neither in $MONGODB_URL nor in --env-file; it is validated (and refused if
# it carries credentials) but never forwarded to the container — the
# container's own environment is always what Prisma actually reads.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./lib/compose-resolve.sh
. "${SCRIPT_DIR}/lib/compose-resolve.sh"

SERVICE="backend"
COMPOSE_PROJECT=""; COMPOSE_FILE=""; ENV_FILE=""; MONGODB_URL_ARG=""

die() { printf '  \xe2\x9c\x97 %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --compose-project) COMPOSE_PROJECT="${2:?--compose-project needs a value}"; shift ;;
    --compose-file)    COMPOSE_FILE="${2:?--compose-file needs a value}"; shift ;;
    --env-file)        ENV_FILE="${2:?--env-file needs a value}"; shift ;;
    --service)         SERVICE="${2:?--service needs a value}"; shift ;;
    --mongodb-url)     MONGODB_URL_ARG="${2:?--mongodb-url needs a value}"; shift ;;
    -h|--help)         sed -n '2,42p' "$0"; exit 0 ;;
    *) die "unknown flag: $1 (try --help)" ;;
  esac
  shift
done
[ -n "${COMPOSE_PROJECT}" ] && [ -n "${COMPOSE_FILE}" ] || \
  die "--compose-project and --compose-file are required (try --help)"

# --- Resolve the URL to VALIDATE (never forwarded to the container; never
# printed in full — only its host, below) --------------------------------
# A URL given directly on this command's own argv is the only form that can
# ever appear in `ps`/shell history here, so it is the only form checked
# for embedded credentials. Env vars and file contents are not argv-visible.
_has_argv_credentials() {  # $1 = url; true if it embeds user:pass@
  case "$1" in
    *://*@*) return 0 ;;
    *) return 1 ;;
  esac
}

url=""
if [ -n "${MONGODB_URL_ARG}" ]; then
  if _has_argv_credentials "${MONGODB_URL_ARG}"; then
    die "--mongodb-url carries embedded credentials (user:pass@) on the command line — refused (secrets never belong on argv; ps and shell history would see it). Omit the credentials, or let this command read MONGODB_URL from the stack's own environment / --env-file instead. Nothing was changed."
  fi
  url="${MONGODB_URL_ARG}"
elif [ -n "${MONGODB_URL:-}" ]; then
  url="${MONGODB_URL}"
elif [ -n "${ENV_FILE}" ] && [ -f "${ENV_FILE}" ]; then
  url="$(grep -E '^MONGODB_URL=' "${ENV_FILE}" | tail -1 | cut -d= -f2-)"
fi
[ -n "${url}" ] || die "no MongoDB address to validate (set \$MONGODB_URL, pass --env-file, or --mongodb-url) — refusing rather than guessing which database this would run against. Nothing was changed."

# --- Host-only extraction (the full URL, which may carry credentials, is
# NEVER printed anywhere below — only the host) ---------------------------
_mongo_url_host() {  # $1 = a mongodb:// URL; prints ONLY the host
  local rest="${1#*://}"
  rest="${rest#*@}"      # strip userinfo if present; no-op if absent
  rest="${rest%%/*}"     # strip path
  rest="${rest%%\?*}"    # strip query, if path-stripping left one
  rest="${rest%%,*}"     # a replica-set URL's first host only
  printf '%s' "${rest%%:*}"   # strip port
}

EVENT_STORE_LOCAL_HOSTS="${EVENT_STORE_LOCAL_HOSTS:- localhost 127.0.0.1 ::1 mongodb }"

# _is_local_host <host> — true if <host> is on the local allowlist. Shared
# by both the host-side check (below) and the container-side check
# (further down) so the two can never silently drift apart.
_is_local_host() {
  case " ${EVENT_STORE_LOCAL_HOSTS} " in
    *" $1 "*) return 0 ;;
    *) return 1 ;;
  esac
}

host="$(_mongo_url_host "${url}")"
_is_local_host "${host}" || \
  die "MongoDB host '${host}' is not a recognized LOCAL address (localhost/127.0.0.1/::1/the 'mongodb' compose-network alias) — refusing to sync indexes against a non-local event store. Nothing was changed."

# --- Resolve Compose v2 through the one shared resolver (AXI-1971/FR54) --
compose_resolve || die "${COMPOSE_RESOLVE_ERROR}"

compose_cmd=("${COMPOSE_ARGS[@]}" -p "${COMPOSE_PROJECT}" -f "${COMPOSE_FILE}")
[ -z "${ENV_FILE}" ] || compose_cmd+=(--env-file "${ENV_FILE}")

# --- Container-side host check (AXI-1971 review fix #3): the host-side
# check above validates the URL *this command* was told about, but
# `prisma db push` below runs INSIDE the container and reads the
# CONTAINER's OWN $MONGODB_URL (set by docker-compose.yml), which can
# legitimately differ from whatever this command was told on its own argv/
# env-file/--mongodb-url. Read ONLY the host from inside the container —
# never the full URL, which may carry credentials — so nothing
# credential-bearing ever reaches this process's argv, stdout, or logs.
# The extraction script below is deliberately the exact same algorithm as
# _mongo_url_host() above, just written once more in POSIX sh so it runs
# unmodified inside the container's own shell.
container_host="$("${compose_cmd[@]}" exec -T "${SERVICE}" sh -lc \
  'u="$MONGODB_URL"; u="${u#*://}"; u="${u#*@}"; u="${u%%/*}"; u="${u%%\?*}"; u="${u%%,*}"; printf "%s" "${u%%:*}"' \
  2>/dev/null)" && container_host_rc=0 || container_host_rc=$?

if [ "${container_host_rc}" -ne 0 ] || [ -z "${container_host}" ]; then
  die "could not read the ${SERVICE} container's own MONGODB_URL host (the read either failed or returned nothing) — refusing to assume it is local. Checked: the container's own \$MONGODB_URL, via 'compose exec ${SERVICE} sh -lc ...' printing only the host. Nothing was changed."
fi
_is_local_host "${container_host}" || \
  die "the ${SERVICE} container's own MONGODB_URL host '${container_host}' is not a recognized LOCAL address (localhost/127.0.0.1/::1/the 'mongodb' compose-network alias) — refusing to sync indexes against what the container would actually use, even though the host-side address checked out. Nothing was changed."

# --- The sync itself: Prisma's OWN index definition, no data-loss flag ---
# Deliberately `exec` (not `run`): this is a maintenance command against an
# ALREADY-RUNNING local stack, never a start/up step — see the header.
printf '  ==> syncing event-store indexes on %s (host: %s; container host: %s)\n' "${COMPOSE_PROJECT}" "${host}" "${container_host}"
"${compose_cmd[@]}" exec -T "${SERVICE}" sh -lc \
  'npx prisma db push --schema=apps/event-service/src/prisma/schema.prisma --skip-generate' \
  || die "index sync failed — see Prisma's own output above. If it refused a potentially destructive change, that is this command's fail-closed behaviour, not a bug: it never passes a data-loss-accepting flag. Nothing further was attempted."
printf '  \xe2\x9c\x93 event-store indexes synced (idempotent; safe to re-run).\n'
