# Running a Claude-harness worktree against the local dev stack

How to point the dockerized dev stack (`make local-up`) at a Claude Code
worktree (`.claude/worktrees/<name>/`) instead of the primary checkout, so a
branch built in a worktree can be clicked through in a real browser before
it's merged. This is the fast path — skip straight to §6 if you've done this
before and just need the commands.

> This is a *different* worktree convention from the one
> [docker-compose.override.yml.example](../docker-compose.override.yml.example)
> documents (`_worktrees/<repo>-<branch>`, a manual `git worktree add` layout).
> A Claude-harness worktree lives at
> `<repo-root>/.claude/worktrees/<name>/<submodule>/` instead — same override
> mechanism, different path.

---

## 1. Why this is more setup than a normal worktree

A Claude-harness worktree of `axiome-global` is a full checkout of the
super-repo, but its submodules (`axiome-front`, `axiome-back`, `axiome-infra`,
...) come back **uninitialized** — `git submodule update --init` has never run
there. Two consequences:

- Nothing under `axiome-front/`, `axiome-back/`, etc. exists until you init
  the submodules you need.
- The submodule pointer the superproject records is whatever commit was
  current when the worktree's branch diverged — usually **stale** relative to
  each submodule's own `origin/main`, sometimes by dozens of commits.

---

## 2. Init and fast-forward the submodules you need

Only init what the task touches — each is a full clone.

```bash
git submodule update --init axiome-front axiome-back axiome-infra
```

For each one, check it out on `main` and fast-forward — do **not** trust the
commit the worktree checked out to:

```bash
cd axiome-front
git checkout main && git merge --ff-only origin/main
cd ../axiome-back
git checkout main && git merge --ff-only origin/main
cd ../axiome-infra
git checkout main && git merge --ff-only origin/main
```

If a submodule is on a real feature branch rather than `main`, fetch and
check that branch out instead — the point is just "not the stale pointer".

---

## 3. `node_modules` for standalone tsc/vitest (optional)

A fresh worktree has no `node_modules`. If you need to run `tsc --noEmit`,
`vitest`, etc. *outside* Docker, symlink the primary checkout's:

```bash
ln -s /path/to/axiome-global/axiome-front/node_modules axiome-front/node_modules
```

**Remove this symlink before step 5** — `make local-up` mounts the whole
service directory into the container, and a symlinked `node_modules` breaks
that mount ("not a directory"). The Makefile also mounts a real
`frontend_node_modules` Docker volume over `/app/node_modules` inside the
container, so the container never needs your symlink anyway.

```bash
rm axiome-front/node_modules
```

---

## 4. Check what's already running before you touch anything

Container names in `docker-compose.yml` are fixed (`axiome-frontend`,
`axiome-backend`, ...) — bringing up a service **recreates** the same
container wherever it's currently pointed, it doesn't add a second one. If a
stack is already running (e.g. against the primary checkout), `make local-up`
here will silently repoint and restart it.

```bash
docker ps --format 'table {{.Names}}\t{{.Status}}'
docker inspect axiome-frontend --format '{{range .Mounts}}{{.Source}} -> {{.Destination}}{{"\n"}}{{end}}'
```

If someone's dev session is running against the primary checkout, ask before
repointing it — don't assume it's free to take over.

Only touch the services your change actually needs. `postgres` / `minio` /
`redis` / `rabbitmq` / `mongodb` are shared data services with nothing
worktree-specific to mount — leave them running against whatever they're
already attached to. If your worktree's `axiome-back` is on the same commit
as the primary checkout's (check `git log -1 --oneline` in both), there's no
reason to repoint `backend` either — a frontend-only change only needs
`frontend` recreated.

---

## 5. Point the stack at the worktree

`docker-compose.override.yml` in `axiome-infra/` (gitignored, machine-local,
auto-merged by every `make local-*` target) overrides a service's `volumes:`.
Point it at the worktree's **absolute path**, not the
`_worktrees/<repo>-<branch>` convention from the `.example` file — that
convention doesn't apply to Claude-harness worktrees:

```yaml
# axiome-infra/docker-compose.override.yml
services:
  frontend:
    volumes:
      - /absolute/path/to/.claude/worktrees/<name>/axiome-front:/app
      - frontend_node_modules:/app/node_modules
```

Add a `backend:` block the same way only if the worktree's `axiome-back`
actually diverges from the primary checkout's.

```bash
cd axiome-infra
make local-up SERVICE=frontend    # add SERVICE=backend too if you overrode it
docker logs axiome-frontend --tail 30    # confirm Vite came up clean
```

---

## 6. Fast path (already done this once)

```bash
git submodule update --init axiome-front               # + axiome-back, axiome-infra as needed
(cd axiome-front && git checkout main && git merge --ff-only origin/main)
rm -f axiome-front/node_modules                         # only if you'd symlinked it for tsc
docker ps --format 'table {{.Names}}\t{{.Status}}'       # check nothing else is using these containers
# write axiome-infra/docker-compose.override.yml pointing frontend: at this worktree's axiome-front
cd axiome-infra && make local-up SERVICE=frontend
```

The app is then live at `http://localhost:5173` with your worktree's code —
browser session auth/data from whatever was last logged in there carries
over, so an already-authed browser tab is usually good to go immediately.

To restore afterward, see §7 — deleting the override file alone does **not**
put the primary checkout back.

---

## 7. When you're done

**Deleting the override is not enough to restore the primary checkout.**
`docker-compose.yml`'s own `frontend.volumes` path is relative to
`axiome-infra/`'s own directory — run `make local-up` with no override from
*this worktree's* `axiome-infra`, and it happily resolves that relative path
against the worktree again, not the primary checkout. (Confirmed the hard
way: `rm docker-compose.override.yml && make local-up SERVICE=frontend` left
`axiome-frontend` mounted on the worktree.)

Write a **temporary** override pointing at the primary checkout's absolute
path instead, apply it, then delete it:

```bash
cat > axiome-infra/docker-compose.override.yml <<'EOF'
services:
  frontend:
    volumes:
      - /absolute/path/to/axiome-global/axiome-front:/app
      - frontend_node_modules:/app/node_modules
EOF
cd axiome-infra && make local-up SERVICE=frontend
docker inspect axiome-frontend --format '{{range .Mounts}}{{.Source}} -> {{.Destination}}{{"\n"}}{{end}}'   # confirm it's the primary checkout, not the worktree
cd .. && rm axiome-infra/docker-compose.override.yml
```

The container itself doesn't revert when the file disappears — only the next
`make local-up` reads it, so removing the override after the container is
already recreated is safe and just leaves the worktree clean for next time.
