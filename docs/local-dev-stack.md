# Local dev stack — the one-DB fixed-port stack (`make local-up`)

How to run the full Axiome platform locally: **main code, the real APHM / Biotech
One data, fixed ports, no reinstall, and it runs offline.** This is the default
path for everyday local work as of 2026-09-04.

> **Relationship to per-worktree isolation.** The multi-stack, one-database-per-worktree
> model in [`claude-worktree-local-dev.md`](claude-worktree-local-dev.md) still exists
> (`./scripts/wt-up.sh` directly) for the rare case where you genuinely need a private,
> throwaway stack. But the `make local-*` targets no longer use it — they now drive the
> single shared stack described here. One database, one of each commodity service, for
> every worktree.

---

## 1. TL;DR

```bash
cd axiome-infra
make local-up          # start (== make demo-up); front :5173, API :3000, biocompute :8000
#   open http://localhost:5173   login: admin@cro-one.com / admin  (SUPER ADMIN)
make local-logs        # follow logs        (SERVICE=backend to scope)
make local-down        # stop (containers kept — next start is instant)
```

- **First `local-up` builds one image** (`axiome-demo-node:local`, ~1 min, needs network once).
- **Every start after that is instant and offline** — no `npm install`, no image pull.

---

## 2. Shape of the stack

Two layers on one shared docker network (`axiome-shared-net`):

### The one data layer (shared by everything)

| Service | Container | Notes |
|---|---|---|
| PostgreSQL | **`axiome-localhost`** (`postgres:15`) | THE database — DB `axiome`, schemas `user_svc` / `organization_svc`. Holds the migrated **APHM / Biotech One** data. |
| MongoDB | `axiome-shared-mongodb-1` (`mongo:7`) | Event store, DB `axiome-global-axi-1233`. |
| Redis | `axiome-shared-redis-1` | DB index 1, prefix `axiome:shared:`. |
| RabbitMQ | `axiome-shared-rabbitmq-1` | vhost `axiome-global-axi-1233`. |
| MinIO | `axiome-shared-minio-1` | Buckets `axiome-global-axi-1233-{uploads,artifacts,system}`. |

There is **exactly one** of each. Do not create per-worktree databases/buckets any
more — every worktree points its app services at these same resources.

### The app layer (`docker-compose.demo.yml`, compose project `axiome-demo`)

| Service | Container | Host port | Image | Code |
|---|---|---|---|---|
| Backend (gateway + user + event + organization) | `axiome-demo-backend` | **3000** | `axiome-demo-node:local` (built) | bind-mount `axiome-back` (main checkout) |
| Frontend | `axiome-demo-frontend` | **5173** | `node:20-slim` | bind-mount `axiome-front` |
| Bio-compute | `axiome-demo-biocompute` | **8000** | `axiome-…-biocompute` | bind-mount `axiome-bio-compute` |

Each app service **bind-mounts the primary checkout and uses its on-disk
`node_modules` directly** — there is no empty `node_modules` volume overlaid on top,
which is what used to force a reinstall on every start. `npm install` runs **only**
if `node_modules` is genuinely absent.

The four backend services run in one container via
`concurrently → nest start <svc> --watch`.

---

## 3. Why the backend image is glibc (`node:20-slim`), not alpine

This is the load-bearing detail that makes "reuse the on-disk `node_modules`" work.

The `node_modules` we bind-mount is **built for glibc** (it was installed on the host
or in a Debian container). Its native modules therefore link against glibc:

- **`bcrypt`** ships **only a glibc** native binding (`bcrypt_lib.node` needs
  `libc.so.6`). It has no musl variant on disk.
- `sharp` carries both glibc and musl variants; Prisma engines are per-`binaryTarget`.

Run that glibc `node_modules` on **`node:20-alpine` (musl)** and `bcrypt.hash` — called
in user-service's admin-bootstrap hook — **segfaults (SIGSEGV, exit 139)** the instant
it loads, right after `User database connected`. Symptom: user-service never binds
**:3002**, so the gateway returns **`503 Auth service unavailable`** on every
`/auth/login`. It looks like a hang; it is a native crash.

**Fix:** run the app on a **glibc** image (`node:20-slim`), matching the host-built
modules. `bcrypt` loads, user-service binds :3002, auth works.

> The canonical `docker-compose.yml` / `axiome-back/Dockerfile` stay on alpine **on
> purpose** — they `npm install` *inside* the alpine image, producing a musl `bcrypt`.
> The demo stack deliberately diverges to glibc precisely so it can skip that reinstall
> and mount the host modules as-is.

### Prisma engine gotcha

`schema.prisma` has `binaryTargets = ["native", "linux-musl-openssl-3.0.x"]`. Running
`prisma generate` **inside alpine** collapses both targets to musl and **strips the
glibc `debian-openssl-3.0.x` engine** — which then fails on the glibc image. If a
client is missing its glibc engine, copy it from a sibling (all clients share one
Prisma version, so the engine binary is identical):

```bash
cp node_modules/.prisma/organization-client/libquery_engine-debian-openssl-3.0.x.so.node \
   node_modules/.prisma/<other>-client/
```

---

## 4. Offline

**A warm stack runs completely offline.** Everything it needs is local:

| Dependency | Offline because |
|---|---|
| Images | `axiome-demo-node:local`, `node:20-slim`, biocompute — all cached; no `pull_policy: always`. |
| OpenSSL (Prisma) | baked into `node:20-slim`. |
| Chromium (Puppeteer) | baked into `axiome-demo-node:local` (see §6). |
| `node_modules` | on disk (bind-mounted); install skipped. |
| Prisma query engines | on disk (`.so.node` per client). |
| PG / Mongo / Redis / RabbitMQ / MinIO | local containers. |
| Transactional email (Mailjet) | dev-logged, not sent. |

**Network is needed only on cold start** — to build `axiome-demo-node:local` the very
first time, or to `npm install` if `node_modules` is ever deleted. After that, pull the
cable and `make local-up` still comes up serving.

---

## 5. Debugging

| Command | What it does |
|---|---|
| `make local-debug` | Foreground, verbose: `LOG_LEVEL=debug`, `DEBUG=axiome:*`, `BIO_COMPUTE_LOG_LEVEL=DEBUG`, Node source maps. |
| `make local-inspect` | Restarts the backend with each Nest service under the **Node inspector**. |
| `make local-logs [SERVICE=x]` | Follow logs. |
| `make local-shell SERVICE=backend` | Shell into a container. |
| `make local-exec SERVICE=x CMD="…"` | Run a command in a container. |

Inspector ports (published to the host):

| Service | Port |
|---|---|
| gateway | 9229 |
| user-service | 9230 |
| event-service | 9231 |
| organization-service | 9232 |

Attach from VS Code or `chrome://inspect` to `localhost:<port>`; `make local-up`
returns to the normal, non-inspected stack. The mode is driven by the `INSPECT` env var
read in `docker/demo-backend-entrypoint.sh`.

---

## 6. The custom backend image

`docker/demo-node.Dockerfile` = `node:20-slim` + system **Chromium** + `openssl` +
`docker/demo-backend-entrypoint.sh`, built to the fixed local tag
`axiome-demo-node:local`. Chromium is baked so Puppeteer screenshot / PDF-export
features work offline; Puppeteer is pointed at it via
`PUPPETEER_EXECUTABLE_PATH=/usr/bin/chromium` (and `PUPPETEER_SKIP_DOWNLOAD=true`).

The entrypoint installs `node_modules` only if absent, then branches on `INSPECT` to run
either the debugger-attached services or plain `npm run dev`.

Rebuild it (rarely needed — only if the Dockerfile or entrypoint changes):

```bash
docker compose -p axiome-demo -f docker-compose.demo.yml build backend
```

---

## 7. Make target reference

All `local-*` targets now drive the `axiome-demo` stack:

| Target | Action |
|---|---|
| `local-up` | alias of `demo-up` — start (build image first time), fixed ports |
| `local-down` | stop containers (keep them; next start instant) |
| `local-restart` | restart (optionally `SERVICE=x`) |
| `local-logs` / `local-tail` | follow / print logs |
| `local-debug` | foreground + verbose |
| `local-inspect` | debugger-attached backend (9229-9232) |
| `local-shell` / `local-exec` | shell / run-command in a container |
| `local-purge` | **disabled** — it would destroy the shared `axiome-localhost` DB (real APHM data). Use `make demo-rm` to remove only the containers. |

The `demo-*` targets (`demo-up/-down/-restart/-logs/-rm`) are the same stack; `local-up`
and `demo-up` are interchangeable.

---

## 8. Known issues

- **org-service overview cron** logs a `PrismaClientUnknownRequestError` every minute:
  `ingestionAuditLog.findMany()` hits an orphaned `ingestion_audit` row whose
  `ingestion` relation is `null` (an artifact of migrating the DB forward). It does not
  affect login or the demo data, but leaves the Overview projection stale until the
  orphaned row is cleaned up.

---

## 9. History (git, `axiome-infra` main)

| Commit | Change |
|---|---|
| `0fea0c7` | Single shared data layer (one DB/mongo/minio) + fast fixed-port demo stack. |
| `7b4a249` | Demo stack on glibc (`node:20-slim`) — fixes the bcrypt SIGSEGV, enables no-reinstall. |
| `d1d4ef3` | `make local-up/-down/-restart/-logs` aliased to the demo stack; `local-purge` disabled. |
| `90604c7` | `local-debug/-shell/-exec` pointed at the demo stack + debug env knobs. |
| `fc4c26f` | Baked Chromium (offline screenshots) + Node inspect mode (`make local-inspect`). |
