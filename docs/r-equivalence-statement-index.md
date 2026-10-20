# R-equivalence statement index — `R_EQUIVALENCE_BASE_URL`

The Evidence Audit Report (epic AXI-2073, story AXI-2081) links each method in a
report to its entry in the Method R-Equivalence Statement (epic AXI-2067). To build
that link, `organization-service` fetches the published statement index once per
report:

```
GET <fetch base>/r-equivalence/index.json
```

Code: `axiome-back/apps/organization-service/src/provenance/audit-report/audit-report-method-link.ts`
(`HttpMethodLinkResolverPort`).

## Two URLs, two jobs

| Variable | Used for | Must be reachable from |
| --- | --- | --- |
| `R_EQUIVALENCE_BASE_URL` | **fetching** `index.json` (server side, 3 s timeout, 1 index per report) | the **organization-service container** |
| `FRONTEND_URL` | the link **printed** in the report (`<FRONTEND_URL>/r-equivalence/<buildSha>/external.html#<anchor>`) | the **reader's browser** |

If `R_EQUIVALENCE_BASE_URL` is unset, the fetch falls back to `FRONTEND_URL`. If that
is also unset, it falls back to `http://localhost:5173`. Inside a container,
`localhost:5173` is the container itself, so the fetch fails.

## What the report shows

| Report text | Meaning |
| --- | --- |
| a link | index loaded, the run's `buildSha` + operation have an entry |
| `none exists` | index loaded, but no entry for this `buildSha` + operation |
| `statement index unavailable` | the fetch failed (unreachable, timeout, non-200, oversized, or not JSON — e.g. nginx's SPA fallback returning `index.html`) |

`statement index unavailable` on every report means this variable is not set
correctly for the environment.

## Where the index comes from

`index.json` is a **static file in the front**: `axiome-front/public/r-equivalence/`.
It is written only by bio-compute CI (`statement.yml` → `publish_front.sh`), which
commits to `axiome-front` main on every bio-compute release. Vite serves `public/**` in
dev. The production front image (nginx) bakes it into `/usr/share/nginx/html` at
build time.

## Value per environment

| Environment | Compose file | Set `R_EQUIVALENCE_BASE_URL` to | Status |
| --- | --- | --- | --- |
| Shared demo stack | `docker-compose.demo.yml` (`axiome-demo-backend`) | `http://axiome-demo-frontend:5173` | set (with `FRONTEND_URL`) |
| Per-worktree stack | `docker-compose.yml` (`backend`) | `http://frontend-${WT_SLUG}:5173` (alias on `axiome-shared-net`) | set (with `FRONTEND_URL`) |
| Production (AWS on-box) | `providers/aws/onbox/docker-compose.yml` (`organization-service`) | `http://axiome-frontend:80` (same `axiome` network) | set to `http://frontend:80` (service name on the `axiome` network); `FRONTEND_URL` stays from SSM |
| Scaleway / on-prem | `providers/scaleway/cloud-init/docker-compose.yml`, `providers/onprem/compose/*.yml` | `http://frontend:80` | set |

Also set `FRONTEND_URL` explicitly on the demo backend (`http://localhost:5173`).
Otherwise the printed link relies on the code default.

Add it under the organization-service `environment:` block, for example (demo):

```yaml
      # AXI-2081: server-side fetch of the R-equivalence statement index
      # (front public/r-equivalence/index.json). Container-reachable, never localhost.
      R_EQUIVALENCE_BASE_URL: http://axiome-demo-frontend:5173
      # Browser-facing base for the link printed in audit reports.
      FRONTEND_URL: http://localhost:5173
```

Then recreate the container (`docker compose -f docker-compose.demo.yml up -d axiome-demo-backend`
or `make demo-up`). A plain `docker restart` does not pick up new environment variables.

## Verify

From inside the organization-service container:

```bash
docker exec <org-service container> node -e \
  "fetch(process.env.R_EQUIVALENCE_BASE_URL + '/r-equivalence/index.json').then(r => r.text()).then(t => console.log(t.slice(0, 200)))"
```

Expect JSON starting with `{"versions":`. If it starts with `<!doctype html>`, the
front image has no `r-equivalence/index.json` (nginx served the SPA fallback). Then
generate one audit report. Its method sections must show a link or `none exists`,
never `statement index unavailable`.

## Traps

- **Release skew → false "none exists".** The index only contains builds that bio-compute
  CI published *and* that are in the **deployed** front image. A run executed on a new
  bio-compute build before the front is rebuilt and redeployed renders `none exists`,
  although the statement exists. Deploy order per bio-compute release: bio-compute →
  (CI publishes into `axiome-front` main) → front image rebuilt + deployed. A code
  change could separate "build not in index" from "method not in build" (follow-up,
  not built).
- **Vite host check.** The front pins `vite ^5.4.2`, and 5.4.8 is installed. Vite ≥ 5.4.12
  rejects requests whose `Host` header is not allowed. After a Vite upgrade, the demo
  fetch to `axiome-demo-frontend:5173` returns 403 → "unavailable", unless
  `server.allowedHosts` includes that name.
- **SPA fallback.** nginx `try_files $uri $uri/ /index.html` returns HTML with status 200
  for a missing `index.json`. The resolver refuses it as malformed, so the report says
  "unavailable", not "none exists".
