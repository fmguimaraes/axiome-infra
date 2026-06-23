# Troubleshooting

Operational troubleshooting for deployed environments. For *how to connect* to a
host, see [connect-and-debug.md](connect-and-debug.md). For Day-0 setup, see
[bootstrapping.md](bootstrapping.md).

---

## Admin login returns 401 (and the gateway shows "unhealthy")

**First documented:** 2026-06-23, production. The two symptoms below look related
but are independent — one is cosmetic, one is the real blocker.

### Symptom A — gateway container is `unhealthy` (cosmetic, not an outage)

`docker compose ps` shows `axiome-gateway ... (unhealthy)` while every other
container is healthy and the app actually serves traffic.

**Cause.** The compose healthcheck probes `http://localhost:3000/health`, but the
NestJS gateway mounts all routes under the `api/v1` global prefix. The real health
endpoint is **`/api/v1/health`**. `/health` returns 404, so the healthcheck fails
forever. You can see it in the logs as a steady stream of:

```
WARN [AllExceptionsFilter] GET /health - 404: Cannot GET /health
```

**Confirm the app is actually up:**

```bash
scripts/platform-debug.sh health     # hits /api/v1/health → {"status":"ok",...}
```

**Fix (open).** Point the healthcheck at `/api/v1/health` in the cloud-init
`docker-compose.yml` (gateway service `healthcheck.test`). Until then, treat
gateway `unhealthy` as a false alarm and verify with the command above.

### Symptom B — `POST /api/v1/auth/login → 401 Invalid credentials`

The login request reaches the server (you see the 401 in the gateway logs), the
route works, user-service is healthy — but the password is rejected.

**Root cause: the bootstrap admin password is re-applied on every start (G5 replay).**
`AdminBootstrapService` runs `onApplicationBootstrap` and **upserts** the admin user
from the SSM parameter `BOOTSTRAP_ADMIN_PASSWORD` every time user-service starts.
So:

- Whatever value is in **SSM is the effective password**, always.
- Any password you set **in the UI silently reverts** on the next user-service
  restart — including every EC2 **stop/start** (each start boots the containers and
  re-runs the upsert). Two stop/starts = two reverts.
- A password "saved in the browser" that no longer matches SSM → 401.

This is tracked as compliance gap **G5** with remediation **FR5** (make bootstrap
create-only and blank the SSM param after first rotation) — see
`axiome-docs/05 - product/features/HDS-Compliance-Gap-Remediation.md`.

**Diagnose:**

```bash
scripts/platform-debug.sh login-test <admin-email>   # → HTTP/1.1 200 OK if SSM pw is correct
```

If that returns 200 but your browser still fails, your browser has a stale password —
the SSM value is authoritative. Reset to a known value:

**Fix — rotate the admin password (authoritative):**

```bash
scripts/reset-admin-password.sh                 # prod, auto-generates a strong pw
scripts/reset-admin-password.sh -p 'My-Pass'    # or set a specific one
```

This writes SSM → refreshes the on-box `.env` → recreates user-service → verifies
login = 200, then prints the new password once. Save it in your password manager.

> ⚠️ **Do not** edit `BOOTSTRAP_ADMIN_PASSWORD` directly in `/opt/axiome/.env` by
> hand with `printf '...\n'` — an unquoted `\n` in `dash` is stripped to a literal
> `n` and gets appended to the password, producing a value that hashes differently
> from what you type (this caused a 45-char vs 44-char mismatch during the original
> incident). Use the script, which writes the line with a quoted `printf '%s\n'`.

### Why connectivity was never the problem

The instance has an **Elastic IP** (`eipassoc-...`), so stop/start does **not**
change the public IP and DNS stays valid. If login attempts show up in the gateway
logs at all, you are reaching the right box — the issue is credentials, not network.

---

## General triage order

1. **Is the app up?** `scripts/platform-debug.sh health` → expect `{"status":"ok"}`.
   Ignore a gateway `unhealthy` flag until this fails (see Symptom A).
2. **What's running?** `scripts/platform-debug.sh status`.
3. **What does the failing service say?** `scripts/platform-debug.sh logs <service> 120`.
4. **Is it auth?** `scripts/platform-debug.sh login-test <email>`.
5. **Anything else** — drop to a raw command: `scripts/ssm-exec.sh '<cmd>'`.
