#!/usr/bin/env bash
# wt-common.sh — shared library for the per-worktree local-dev scripts
# (wt-up.sh / wt-down.sh / wt-status.sh). Sourced, not executed.
#
# Provides: slug derivation, the collision-free port/Redis-index registry at
# ~/.axiome/worktree-registry.json, and thin helpers over the shared stack
# (Postgres / Mongo / Redis / RabbitMQ / MinIO). POSIX-friendly bash; every
# mutation is idempotent and safe to re-run.

# --- Locations -------------------------------------------------------------
WT_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "${WT_COMMON_DIR}/.." && pwd)"        # axiome-infra/ (holds the compose files)
WORKTREE_ROOT="$(cd "${INFRA_DIR}/.." && pwd)"        # the super-repo checkout (= worktree)

SHARED_COMPOSE="${INFRA_DIR}/docker-compose.shared.yml"
APP_COMPOSE="${INFRA_DIR}/docker-compose.yml"
SHARED_PROJECT="axiome-shared"
SHARED_NET="axiome-shared-net"

REGISTRY_DIR="${AXIOME_HOME:-${HOME}/.axiome}"
REGISTRY_FILE="${REGISTRY_DIR}/worktree-registry.json"
REGISTRY_LOCK="${REGISTRY_DIR}/.worktree-registry.lock"

# --- Allocation policy -----------------------------------------------------
BASE_BACKEND_PORT=3000
BASE_FRONTEND_PORT=5173
BASE_BIOCOMPUTE_PORT=8000
PORT_STEP=100
REDIS_MAX_DBS=16                # redis default databases 0..15

# --- Shared-service credentials (must match docker-compose.shared.yml) ------
PG_USER="${POSTGRES_USER:-axiome}"
PG_PASS="${POSTGRES_PASSWORD:-axiome_local_dev}"
PG_ADMIN_DB="${SHARED_POSTGRES_DB:-axiome}"
MONGO_USER="${MONGODB_USER:-axiome}"
MONGO_PASS="${MONGODB_PASSWORD:-axiome_local_dev}"
MQ_USER="${RABBITMQ_USER:-axiome}"
MQ_PASS="${RABBITMQ_PASSWORD:-axiome_local_dev}"
S3_ACCESS_KEY="${S3_ACCESS_KEY:-minioadmin}"
S3_SECRET_KEY="${S3_SECRET_KEY:-minioadmin}"

# --- Pretty logging --------------------------------------------------------
_c_reset=$'\033[0m'; _c_bold=$'\033[1m'; _c_blue=$'\033[34m'; _c_green=$'\033[32m'
_c_yellow=$'\033[33m'; _c_red=$'\033[31m'; _c_dim=$'\033[2m'
log()   { printf '%s==>%s %s\n' "${_c_blue}${_c_bold}" "${_c_reset}" "$*"; }
ok()    { printf '%s  ✓%s %s\n' "${_c_green}" "${_c_reset}" "$*"; }
warn()  { printf '%s  ! %s%s\n' "${_c_yellow}" "$*" "${_c_reset}" >&2; }
die()   { printf '%s  ✗ %s%s\n' "${_c_red}" "$*" "${_c_reset}" >&2; exit 1; }

need_docker() {
  command -v docker >/dev/null 2>&1 || die "docker not found on PATH"
  docker compose version >/dev/null 2>&1 || die "docker compose v2 required"
}

# --- Slug ------------------------------------------------------------------
# Sanitize an arbitrary string into a docker/DNS/DB-safe slug.
wt_slugify() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -e 's/[^a-z0-9]/-/g' -e 's/-\{2,\}/-/g' -e 's/^-//' -e 's/-$//' \
    | cut -c1-40
}

# Derive this worktree's slug: explicit WT_SLUG wins, else the worktree dir name.
wt_derive_slug() {
  if [ -n "${WT_SLUG:-}" ]; then
    wt_slugify "${WT_SLUG}"
  else
    wt_slugify "$(basename "${WORKTREE_ROOT}")"
  fi
}

# --- Registry (JSON at ~/.axiome/worktree-registry.json) -------------------
# All registry access goes through python3 under an flock, so concurrent
# wt-up.sh runs in different worktrees never race on allocation.
_registry_py() {
  # $1 = action, $2 = slug (the registry key). stdin unused.
  mkdir -p "${REGISTRY_DIR}"
  ( flock 9
    SLUG_KEY="${2:-}" WT_PATH="${WORKTREE_ROOT}" INFRA_IN="${INFRA_DIR}" \
    REGISTRY_FILE="${REGISTRY_FILE}" PORT_STEP="${PORT_STEP}" \
    REDIS_MAX_DBS="${REDIS_MAX_DBS}" \
    python3 - "$1" <<'PY'
import json, os, sys, datetime

action = sys.argv[1]
path   = os.environ["REGISTRY_FILE"]
slug   = os.environ["SLUG_KEY"]        # slug is the registry key (the namespace)
step   = int(os.environ["PORT_STEP"])
rmax   = int(os.environ["REDIS_MAX_DBS"])

def load():
    try:
        with open(path) as f:
            d = json.load(f)
    except (FileNotFoundError, ValueError):
        d = {}
    d.setdefault("version", 1)
    d.setdefault("worktrees", {})     # keyed by slug
    return d

def save(d):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(d, f, indent=2, sort_keys=True)
        f.write("\n")
    os.replace(tmp, path)

d = load()
wts = d["worktrees"]

if action == "get":
    e = wts.get(slug)
    if e:
        print("%s\t%d\t%d" % (slug, e["port_offset"], e["redis_db"]))
    sys.exit(0)

if action == "list":
    for s, e in sorted(wts.items(), key=lambda kv: kv[1]["port_offset"]):
        print("%s\t%d\t%d\t%s" % (s, e["port_offset"], e["redis_db"], e.get("path", "")))
    sys.exit(0)

if action == "release":
    if slug in wts:
        del wts[slug]
        save(d)
    sys.exit(0)

if action == "allocate":
    e = wts.get(slug)
    if e:  # idempotent — same slug re-uses its allocation
        print("%s\t%d\t%d" % (slug, e["port_offset"], e["redis_db"]))
        sys.exit(0)
    used_off   = {v["port_offset"] for v in wts.values()}
    used_redis = {v["redis_db"] for v in wts.values()}
    off = 0
    while off in used_off:
        off += step
    rdb = 0
    while rdb in used_redis:
        rdb += 1
    if rdb >= rmax:
        sys.stderr.write("no free Redis DB index (max %d worktrees)\n" % rmax)
        sys.exit(3)
    wts[slug] = {
        "port_offset": off, "redis_db": rdb,
        "path": os.environ["WT_PATH"], "infra_dir": os.environ["INFRA_IN"],
        "created": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
    }
    save(d)
    print("%s\t%d\t%d" % (slug, off, rdb))
    sys.exit(0)

sys.stderr.write("unknown registry action: %s\n" % action)
sys.exit(2)
PY
  ) 9>"${REGISTRY_LOCK}"
}

wt_registry_allocate() { _registry_py allocate "$1"; }   # $1 slug -> "slug\toffset\tredis_db"
wt_registry_get()      { _registry_py get "$1"; }        # $1 slug -> "slug\toffset\tredis_db" or empty
wt_registry_release()  { _registry_py release "$1"; }    # $1 slug
wt_registry_list()     { _registry_py list; }            # -> lines "slug\toffset\tredis_db\tpath"

# --- Shared-stack helpers --------------------------------------------------
shared_compose() { docker compose -p "${SHARED_PROJECT}" -f "${SHARED_COMPOSE}" "$@"; }

shared_running() {
  [ -n "$(docker ps -q --filter "label=com.docker.compose.project=${SHARED_PROJECT}" 2>/dev/null)" ]
}

ensure_shared_net() {
  docker network inspect "${SHARED_NET}" >/dev/null 2>&1 || {
    log "Creating external network ${SHARED_NET}"
    docker network create "${SHARED_NET}" >/dev/null
  }
}

# psql against the shared postgres admin DB (for CREATE/DROP DATABASE etc.)
pg_admin() {  # args after -- go to psql; sql via -c by caller
  shared_compose exec -T postgres psql -v ON_ERROR_STOP=1 -U "${PG_USER}" -d "${PG_ADMIN_DB}" "$@"
}
pg_db_exists() {  # $1 = db name
  local out
  out="$(shared_compose exec -T postgres psql -tAqc \
    "SELECT 1 FROM pg_database WHERE datname='$1'" -U "${PG_USER}" -d "${PG_ADMIN_DB}" 2>/dev/null || true)"
  [ "$(printf '%s' "$out" | tr -d '[:space:]')" = "1" ]
}

redis_cli() { shared_compose exec -T redis redis-cli "$@"; }
rabbitmqctl() { shared_compose exec -T rabbitmq rabbitmqctl "$@"; }

# Run `mc ...` commands against the shared MinIO with alias `local` preset.
mc_sh() {  # $1 = a shell snippet using the `mc` binary and alias `local`
  docker run --rm --network "${SHARED_NET}" --entrypoint /bin/sh minio/mc:latest -c \
    "mc alias set local http://minio:9000 '${S3_ACCESS_KEY}' '${S3_SECRET_KEY}' >/dev/null 2>&1 && $1"
}

# Is the per-worktree app stack (axiome-<slug>) running?
app_running() {  # $1 = slug
  [ -n "$(docker ps -q --filter "label=com.docker.compose.project=axiome-$1" 2>/dev/null)" ]
}

# Derive every per-worktree value from (slug, offset, redis_db) and write the
# gitignored env file. Deterministic: wt-up.sh writes the canonical .env with it;
# wt-down.sh regenerates a throwaway copy from the registry so docker compose can
# interpolate the app compose file. Sets globals (SLUG PROJECT *_PORT PG_DB
# MONGO_DB MQ_VHOST REDIS_DB B_* REDIS_PREFIX) as a side effect for print_summary.
wt_derive_vars() {  # $1=slug $2=offset $3=redis_db
  SLUG="$1"; OFFSET="$2"; REDIS_DB="$3"
  PROJECT="axiome-${SLUG}"
  BACKEND_PORT=$((BASE_BACKEND_PORT + OFFSET))
  FRONTEND_PORT=$((BASE_FRONTEND_PORT + OFFSET))
  BIOCOMPUTE_PORT=$((BASE_BIOCOMPUTE_PORT + OFFSET))
  # SINGLE SHARED DATA LAYER (2026-09-04, user directive): every worktree uses
  # ONE Postgres DB / Mongo DB / MinIO bucket set / RabbitMQ vhost / Redis index,
  # not a per-slug set. Postgres lives on the `axiome-localhost` container (see the
  # DB host in docker-compose.yml); Mongo/MinIO/RabbitMQ/Redis are the shared
  # instances with these fixed names. Ports stay offset-based so two stacks can
  # still run at once — they just share the same data. Revert these five lines to
  # the `${SLUG}`-based values to restore per-worktree isolation.
  PG_DB="axiome"; MONGO_DB="axiome-global-axi-1233"; MQ_VHOST="axiome-global-axi-1233"
  B_UPLOADS="axiome-global-axi-1233-uploads"; B_ARTIFACTS="axiome-global-axi-1233-artifacts"; B_SYSTEM="axiome-global-axi-1233-system"
  REDIS_PREFIX="axiome:shared:"; REDIS_DB=1
}

wt_write_env() {  # $1=file $2=slug $3=offset $4=redis_db
  wt_derive_vars "$2" "$3" "$4"
  cat > "$1" <<EOF
# GENERATED by scripts/wt-up.sh for worktree '${SLUG}'. Gitignored. Do not commit.
# Re-run scripts/wt-up.sh to refresh. See .env.example for the documented template.
WT_SLUG=${SLUG}
PORT_OFFSET=${OFFSET}
BACKEND_PORT=${BACKEND_PORT}
FRONTEND_PORT=${FRONTEND_PORT}
BIOCOMPUTE_PORT=${BIOCOMPUTE_PORT}

POSTGRES_DB=${PG_DB}
MONGODB_DB=${MONGO_DB}
RABBITMQ_VHOST=${MQ_VHOST}
REDIS_DB_INDEX=${REDIS_DB}
REDIS_PREFIX=${REDIS_PREFIX}

S3_ENDPOINT=http://minio:9000
S3_PUBLIC_ENDPOINT=http://localhost:9000
S3_BUCKET=${B_UPLOADS}
S3_BUCKET_UPLOADS=${B_UPLOADS}
S3_BUCKET_ARTIFACTS=${B_ARTIFACTS}
S3_BUCKET_SYSTEM=${B_SYSTEM}
BIO_COMPUTE_S3_BUCKET=${B_ARTIFACTS}

POSTGRES_USER=${PG_USER}
POSTGRES_PASSWORD=${PG_PASS}
MONGODB_USER=${MONGO_USER}
MONGODB_PASSWORD=${MONGO_PASS}
RABBITMQ_USER=${MQ_USER}
RABBITMQ_PASSWORD=${MQ_PASS}
S3_ACCESS_KEY=${S3_ACCESS_KEY}
S3_SECRET_KEY=${S3_SECRET_KEY}
S3_REGION=${S3_REGION:-eu-west-3}

NODE_ENV=development
JWT_SECRET=${JWT_SECRET:-local-dev-jwt-secret-change-in-production}
BOOTSTRAP_ADMIN_EMAIL=${BOOTSTRAP_ADMIN_EMAIL:-admin@axiome.local}
BOOTSTRAP_ADMIN_PASSWORD=${BOOTSTRAP_ADMIN_PASSWORD:-admin}
BOOTSTRAP_ADMIN_FIRST_NAME=Local
BOOTSTRAP_ADMIN_LAST_NAME=Admin

BACKEND_SRC=${BACKEND_SRC:-../axiome-back}
FRONTEND_SRC=${FRONTEND_SRC:-../axiome-front}
BIOCOMPUTE_SRC=${BIOCOMPUTE_SRC:-../axiome-bio-compute}
EOF
}

# Print the resolved resources for the current wt-up.sh run. Reads variables
# set by the caller (SLUG, PROJECT, *_PORT, PG_DB, MONGO_DB, MQ_VHOST,
# REDIS_DB, B_*), so it is only meaningful when sourced into wt-up.sh.
print_summary() {
  printf '\n%s─ worktree %s ─────────────────────────────%s\n' "${_c_bold}" "${SLUG}" "${_c_reset}"
  printf '  %sproject%s        %s\n' "${_c_dim}" "${_c_reset}" "${PROJECT}"
  printf '  %sfrontend%s       http://localhost:%s\n' "${_c_dim}" "${_c_reset}" "${FRONTEND_PORT}"
  printf '  %sbackend API%s    http://localhost:%s/api/v1\n' "${_c_dim}" "${_c_reset}" "${BACKEND_PORT}"
  printf '  %sbiocompute%s     http://localhost:%s\n' "${_c_dim}" "${_c_reset}" "${BIOCOMPUTE_PORT}"
  printf '  %spostgres DB%s    %s  (on shared :5432)\n' "${_c_dim}" "${_c_reset}" "${PG_DB}"
  printf '  %smongo DB%s       %s  (on shared :27017)\n' "${_c_dim}" "${_c_reset}" "${MONGO_DB}"
  printf '  %srabbitmq vhost%s %s  (on shared :5672)\n' "${_c_dim}" "${_c_reset}" "${MQ_VHOST}"
  printf '  %sredis DB index%s %s  (on shared :6379, prefix %s)\n' "${_c_dim}" "${_c_reset}" "${REDIS_DB}" "${REDIS_PREFIX}"
  printf '  %sbuckets%s        %s, %s, %s  (on shared minio :9000)\n' "${_c_dim}" "${_c_reset}" "${B_UPLOADS}" "${B_ARTIFACTS}" "${B_SYSTEM}"
  printf '%s───────────────────────────────────────────%s\n' "${_c_bold}" "${_c_reset}"
}
