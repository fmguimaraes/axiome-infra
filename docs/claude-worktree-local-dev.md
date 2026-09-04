# Per-worktree local dev — isolation strategy

> **For everyday local work, see [`local-dev-stack.md`](local-dev-stack.md) instead.**
> As of 2026-09-04 the `make local-*` targets drive a single shared stack (one
> database — the real APHM data — fixed ports, no reinstall, offline-capable), **not**
> the per-worktree isolation described here. This document covers the isolation model
> that still backs `./scripts/wt-up.sh` for the rare case where you need a private,
> throwaway stack.

How several agent/dev sessions each run the full Axiome platform locally **at the
same time**, in their own git worktrees, without colliding on ports, the docker
compose project, named volumes, databases, or object-storage buckets.

> **This supersedes the old single-stack + `docker-compose.override.yml` approach.**
> That approach pointed *one* stack (fixed container names, fixed host ports, one
> database, one bucket set) at whichever worktree you last edited — so two sessions
> fought over the same containers and data. The override file is still read by the
> legacy `make local-*` targets, but for parallel work use the `wt-*` scripts below.

---

## 1. The problem

The platform is one docker-compose stack: Postgres, MongoDB, Redis, RabbitMQ,
MinIO, plus the app services (backend, biocompute, frontend). Run it twice on one
machine and every layer collides:

- **Host ports** — both stacks want 5432 / 6379 / 9000 / 3000 / 5173 / 8000 …
- **Compose project name** — both default to the directory name, so `up` in one
  worktree *recreates* the other's containers instead of adding new ones.
- **Container names** — pinned `container_name: axiome-backend` etc. mean the
  second `up` silently repoints the first.
- **Data** — one Postgres database, one Mongo event store, one Redis keyspace, one
  bucket set, shared by both → cross-contamination and lost work.

## 2. The strategy — hybrid: share the commodity, duplicate the code

We do **not** duplicate everything per worktree — running five stateful engines
per session would melt the machine. Instead:

- **Stateful commodity services are shared** — exactly one Postgres, Mongo, Redis,
  RabbitMQ, and MinIO for the whole machine (the `axiome-shared` stack). They are
  isolated **logically**, per worktree, *inside* that one instance.
- **Only the services under active development are duplicated** — each worktree
  gets its own backend / biocompute / frontend (the `axiome-<slug>` stack),
  because that is the code you are actually changing and want to run in isolation.

```
                 ┌──────────────────────── one machine ────────────────────────┐
                 │                                                              │
  worktree A ──► │  axiome-<slugA>  (backend, biocompute, frontend)  ┐          │
                 │      ports 3000 / 5173 / 8000                     │          │
                 │                                                   ├─► axiome-shared-net
  worktree B ──► │  axiome-<slugB>  (backend, biocompute, frontend)  │      │   │
                 │      ports 3100 / 5273 / 8100                     ┘      ▼   │
                 │                                          ┌───────────────────┐
                 │   axiome-shared  (ONE each, fixed ports):│ postgres  5432    │
                 │                                          │ redis     6379    │
                 │   logical isolation per worktree:        │ minio  9000/9001  │
                 │     DB <slugA> / <slugB>                 │ mongodb   27017   │
                 │     redis index 0 / 1                    │ rabbitmq  5672     │
                 │     vhost <slugA> / <slugB>              └───────────────────┘
                 │     buckets <slug>-uploads/-artifacts/-system                │
                 └──────────────────────────────────────────────────────────────┘
```

### The slug is the namespace

Everything a worktree owns is derived from a **slug** (the sanitized worktree
directory name, or an explicit `WT_SLUG`): the compose project (`axiome-<slug>`),
container/volume/network-alias names, the Postgres and Mongo database, the
RabbitMQ vhost, the Redis key prefix, and the bucket names. Two worktrees can
therefore never touch the same named resource.

### Ports are offset, not fixed

Each worktree gets a `PORT_OFFSET` (0, 100, 200, …) allocated collision-free from
a machine-local registry (`~/.axiome/worktree-registry.json`). Published host
ports are `base + PORT_OFFSET` — backend `3000+off`, frontend `5173+off`,
biocompute `8000+off`. No compose file pins a host port, and no `container_name`
is pinned anywhere.

### One network, slug-scoped app hostnames

The shared stack publishes an **external** network, `axiome-shared-net`. Every
app stack attaches to it to reach `postgres` / `redis` / `minio` / `mongodb` /
`rabbitmq` by name (there is only one of each, so the name is unambiguous).
App-to-app calls use **slug-scoped aliases** (`backend-<slug>`, `biocompute-<slug>`)
so that two worktrees' `backend`s never shadow each other on the shared network.

### Logical isolation, service by service

| Shared service | Isolation per worktree | Set via |
|---|---|---|
| Postgres | one **database** `<slug>` on the shared instance (never a 2nd container); schemas `user_svc` / `organization_svc` live inside it | `POSTGRES_DB`, `DATABASE_URL` |
| MongoDB (event store) | one **database** `<slug>` | `MONGODB_DB`, `MONGODB_URL` |
| Redis | one **logical DB index** (0–15) + reserved `axiome:<slug>:` key prefix | `REDIS_DB_INDEX` (in `REDIS_URL` path), `REDIS_PREFIX` |
| RabbitMQ | one **vhost** `<slug>` with full app-user permissions | `RABBITMQ_VHOST`, `RABBITMQ_URL` |
| MinIO | one **bucket set** `<slug>-uploads` / `-artifacts` / `-system` (versioning on artifacts); shared endpoint + creds, disjoint namespace | `S3_BUCKET*`, `BIO_COMPUTE_S3_BUCKET` |

**Application code must read these names from env — never build a bucket/DB/URL
from a literal.** A hardcoded name or port defeats the whole scheme.

## 3. The scripts

All in `axiome-infra/scripts/` (POSIX bash, idempotent, safe to re-run):

- **`wt-up.sh`** — derive the slug, allocate a free `PORT_OFFSET` + Redis index,
  write the gitignored `.env`, bring up `axiome-shared` (wait for health), create
  this worktree's Postgres DB / RabbitMQ vhost / MinIO buckets, start the app
  stack (`docker compose -p axiome-<slug> up -d --build`), run migrations, and
  print the resolved URLs / DB / index / buckets.
  Flags: `--shared-only` (just the shared stack), `--provision-only` (everything
  except starting the app services), `--no-seed`.
- **`wt-down.sh`** — `docker compose -p axiome-<slug> down -v` for this project
  only (leaves the shared stack and every other worktree running). `--purge` also
  drops this worktree's Postgres + Mongo DB, flushes its Redis index, deletes its
  vhost + buckets, and frees its registry entry. Purge is opt-in, never default.
  `--shared` / `--purge-shared` stop the machine-wide shared stack (not a
  feature-task action).
- **`wt-status.sh`** — list every worktree stack with its ports, database, Redis
  index, vhost, buckets, and up/down state. `--verify` also probes the shared
  services. This is how you find your own resources.

## 4. Daily workflow

```bash
cd <your-worktree>/axiome-infra
./scripts/wt-up.sh              # start your isolated stack; prints your URLs
# … develop; app is at the printed frontend/backend ports …
./scripts/wt-status.sh         # see every running worktree stack on the machine
./scripts/wt-down.sh           # stop your stack at task end (keeps data + ports)
./scripts/wt-down.sh --purge   # …or also destroy this worktree's data + free its slot
```

The gitignored `.env` is generated by `wt-up.sh`; `.env.example` documents every
variable and how each per-worktree value is derived.

## 5. Rules (see SDLC)

The parallel-agent working rules — one task per worktree, migration
serialisation, treating the shared stack / bucket layout as a serialised shared
surface, teardown as part of task completion — live in
[`axiome-docs/SDLC.md` → Parallel Agent Working Rules](../../axiome-docs/SDLC.md#parallel-agent-working-rules-worktree-isolation)
and the **Local environment** section of the root `CLAUDE.md`.
