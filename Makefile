.PHONY: init plan apply destroy \
        shared-up shared-down \
        local-up local-up-fg local-down local-purge local-restart \
        local-logs local-tail local-ps local-stats \
        local-shell local-exec local-debug local-health \
        analytics-up analytics-down analytics-logs analytics-ps analytics-role analytics-test \
        analytics-connect-prod \
        seed seed-env \
        deploy-prod \
        fmt validate help

ENV ?= dev

# Terraform operations
init:
	terraform init -backend-config=environments/$(ENV)/backend.hcl

plan:
	terraform plan -var-file=environments/$(ENV)/terraform.tfvars

apply:
	terraform apply -var-file=environments/$(ENV)/terraform.tfvars

destroy:
	terraform destroy -var-file=environments/$(ENV)/terraform.tfvars

# Local development — per-worktree isolation model
#
# The local stack is split (see scripts/wt-*.sh and
# docs/claude-worktree-local-dev.md): ONE shared services stack per machine
# (project axiome-shared: postgres/mongo/redis/rabbitmq/minio, docker-compose.shared.yml)
# and per-worktree app stacks (project axiome-<slug>: backend/biocompute/frontend,
# docker-compose.yml). These legacy `make local-*` targets are a thin SOLO-dev
# wrapper that drives that model under a fixed slug (LEGACY_SLUG, default `local`)
# via the wt-* scripts. For PARALLEL sessions call scripts/wt-up.sh directly — it
# allocates a collision-free slug/port-offset per worktree; `make local-*` always
# uses the one `local` slug and must not be run from two worktrees at once.
DOCKER_COMPOSE  := $(shell docker compose version >/dev/null 2>&1 && echo "docker compose" || echo "docker-compose")
LEGACY_SLUG     ?= local
SHARED_PROJECT  := axiome-shared
APP_PROJECT     := axiome-$(LEGACY_SLUG)
SHARED_FILE     := docker-compose.shared.yml
APP_FILE        := docker-compose.yml
ENV_FILE        := .env
# Shared services (postgres/redis/...) and this slug's app services. `$(APP)` needs
# the per-worktree $(ENV_FILE), which `make local-up` (wt-up.sh) writes — run it first.
SHARED := $(DOCKER_COMPOSE) -p $(SHARED_PROJECT) -f $(SHARED_FILE)
APP    := $(DOCKER_COMPOSE) -p $(APP_PROJECT) --env-file $(ENV_FILE) -f $(APP_FILE)

# Behavior Tracking read layer (Metabase over the deployment DB — AXI-1048).
# Runs in the SHARED project on axiome-shared-net and reads the shared Postgres.
# The shared stack must be up first (`make shared-up` or `make local-up`) — that
# is what creates the network.
ANALYTICS_FILE    := analytics/docker-compose.analytics.yml
# Metabase runs as part of the shared project (both files) so it shares the
# lifecycle/network and compose doesn't treat the shared services as orphans.
ANALYTICS_COMPOSE := $(DOCKER_COMPOSE) -p $(SHARED_PROJECT) -f $(SHARED_FILE) -f $(ANALYTICS_FILE)
METABASE_SERVICES := metabase-db-init metabase

# Optional args:
#   SERVICE=<name>   limit a target to one service (backend, biocompute, frontend, postgres, ...)
#   TAIL=<n>         number of log lines to show (default 200)
#   CMD="..."        command to run inside the container (for local-exec)
SERVICE ?=
TAIL    ?= 200

# Start (or refresh) the shared services stack only (machine-wide).
shared-up:
	./scripts/wt-up.sh --shared-only

# Stop the shared services stack (machine-wide — stops EVERY worktree's data
# services). Not a feature-task action. Add PURGE=1 to also delete shared volumes.
shared-down:
	./scripts/wt-down.sh $(if $(PURGE),--purge-shared,--shared)

# Bring up the `local`-slug stack: shared services + this slug's app services,
# create its DB/vhost/buckets, and run migrations (full wt-up.sh). With
# SERVICE=<name>, provisions then (re)builds just that one app service.
local-up:
	@if [ -n "$(SERVICE)" ]; then \
		WT_SLUG=$(LEGACY_SLUG) ./scripts/wt-up.sh --provision-only; \
		$(APP) up -d --build $(SERVICE); \
	else \
		WT_SLUG=$(LEGACY_SLUG) ./scripts/wt-up.sh; \
	fi

# Foreground mode: streams all logs live; Ctrl-C stops the app stack.
local-up-fg:
	WT_SLUG=$(LEGACY_SLUG) ./scripts/wt-up.sh --provision-only
	$(APP) up $(SERVICE)

# Stop THIS slug's app stack (down -v). Leaves the shared stack + data intact.
local-down:
	./scripts/wt-down.sh --slug $(LEGACY_SLUG)

# Also destroy this slug's data (DB / mongo / redis index / vhost / buckets) and
# free its registry allocation.
local-purge:
	./scripts/wt-down.sh --slug $(LEGACY_SLUG) --purge

local-restart:
	$(APP) restart $(SERVICE)

# Follow logs (all app services, or one with SERVICE=<name>).
local-logs:
	$(APP) logs -f --tail=$(TAIL) $(SERVICE)

# Print last N lines and exit (non-following). Useful for CI / scripts.
local-tail:
	$(APP) logs --tail=$(TAIL) $(SERVICE)

# Show running containers and their state (app + shared).
local-ps:
	@$(APP) ps
	@echo "--- shared ---"
	@$(SHARED) ps

# Live resource usage (CPU / mem / net / io) for running containers.
local-stats:
	docker stats

# Print healthcheck status for every app service that defines one.
local-health:
	$(APP) ps --format 'table {{.Name}}\t{{.State}}\t{{.Status}}'

# Open an interactive shell inside an app service container.
# Usage: make local-shell SERVICE=backend
local-shell:
	@if [ -z "$(SERVICE)" ]; then \
		echo "Usage: make local-shell SERVICE=<service-name>"; exit 1; \
	fi
	$(APP) exec $(SERVICE) sh

# Run an arbitrary command inside an app service container.
# Usage: make local-exec SERVICE=backend CMD="npm test"
local-exec:
	@if [ -z "$(SERVICE)" ] || [ -z "$(CMD)" ]; then \
		echo 'Usage: make local-exec SERVICE=<name> CMD="<command>"'; exit 1; \
	fi
	$(APP) exec $(SERVICE) sh -c '$(CMD)'

# Bring the app stack up in the foreground with verbose application logging.
# Overrides LOG_LEVEL / DEBUG flags for the duration of the run only.
local-debug:
	WT_SLUG=$(LEGACY_SLUG) ./scripts/wt-up.sh --provision-only
	BIOCOMPUTE_LOG_LEVEL=DEBUG \
	LOG_LEVEL=debug \
	NODE_OPTIONS=--enable-source-maps \
	DEBUG=$${DEBUG:-axiome:*} \
	PYTHONUNBUFFERED=1 \
	$(APP) up $(SERVICE)

# Behavior Tracking / Metabase read layer (AXI-1048) --------------------------
#
# Metabase runs as an overlay next to the base stack, reading the deployment's
# own Postgres. Bring the base stack up first (`make local-up`); then:
#   make analytics-up            start Metabase (http://localhost:$$METABASE_PORT, default 3001)
#   make analytics-role          create/refresh the read-only metabase_ro role on the axiome DB
#   make analytics-down          stop and remove only the Metabase containers
# Cloud/on-prem: export METABASE_ENCRYPTION_KEY and METABASE_PORT from the
# secrets store before `analytics-up`; see analytics/README.md.
analytics-up:
	$(ANALYTICS_COMPOSE) up -d $(METABASE_SERVICES)

# Stops and removes only the Metabase containers — leaves the base stack running.
analytics-down:
	$(ANALYTICS_COMPOSE) rm -sf $(METABASE_SERVICES)

# Follow Metabase logs (add TAIL=<n> to change the number of lines).
analytics-logs:
	$(ANALYTICS_COMPOSE) logs -f --tail=$(TAIL) metabase

# Show the Metabase containers and their state.
analytics-ps:
	$(ANALYTICS_COMPOSE) ps $(METABASE_SERVICES)

# Create/refresh the least-privilege read-only role Metabase connects as.
# Runs the role SQL inside the postgres container against the axiome DB. Set a
# real metabase_ro password from the secrets store for cloud/on-prem (the SQL
# ships a change_me_readonly placeholder — never use it in prod).
analytics-role:
	$(SHARED) exec -T postgres psql -U $${POSTGRES_USER:-axiome} -d $${POSTGRES_DB:-$(LEGACY_SLUG)} \
		< analytics/funnels/00_metabase_readonly_role.sql

# End-to-end test of the read layer: Metabase health, the read-only role, its
# least-privilege enforcement, and all six funnel queries against seeded events
# (seeded rows are removed on exit). Set MB_USER/MB_PASSWORD to also round-trip
# through Metabase's own /api/dataset. Requires the base stack + analytics-role.
analytics-test:
	analytics/test/e2e-analytics.sh

# Open a READ-ONLY psql shell to the PRODUCTION database as metabase_ro — the prod
# analogue of the local `docker compose exec postgres psql`. The prod RDS is
# PRIVATE and the EC2 box has no SSH, so this tunnels to RDS over AWS SSM (the same
# access path as scripts/ssm-exec.sh) and runs psql through the tunnel; only the
# read-only role is used, never master/app credentials. Prerequisites and the
# credential source (METABASE_RO_PROD_PASSWORD via the repo-root .env.local) are
# documented in analytics/connect-prod-db.sh and analytics/README.md.
#   make analytics-connect-prod
analytics-connect-prod:
	analytics/connect-prod-db.sh

# Seed a clean environment to its known baseline (AXI-1001, FR4/FR5/NFR4):
# reference data, system rule packs, bootstrap roles/users. Idempotent —
# safe to re-run. Fails closed (non-zero exit) on any expected-vs-actual
# mismatch; see scripts/seed-environment.sh for the verification summary.
#   make seed                    seed the local docker-compose stack
#   make seed-env ENV=staging    seed a deployed environment via SSM
seed:
	set -a; [ -f $(ENV_FILE) ] && . ./$(ENV_FILE); set +a; scripts/seed-environment.sh --local

seed-env:
	scripts/seed-environment.sh -e $(ENV)

# --- Authoritative production deploy (AXI-1349, FR12/AC15) ---------------------
# The SINGLE command that actually changes what production runs (closes the
# promote≠deploy gap: the CI promote job only bumps the manifest and is inert).
# Advances ECR :stable -> the chosen image, rolls the box over SSM (pull +
# `prisma migrate deploy` + up), health-checks /api/v1/health, records the action,
# and fails closed (prior image keeps serving) on an unhealthy result.
#   make deploy-prod ENV=production TAG=<sha>            # execute the deploy
#   make deploy-prod ENV=production TAG=<sha> DRY_RUN=1  # print the plan, mutate nothing
# SERVICE defaults to backend; pass SERVICE=frontend|biocompute for the others.
deploy-prod:
	ENV=$(ENV) TAG=$(TAG) SERVICE=$(SERVICE) DRY_RUN=$(DRY_RUN) scripts/deploy-prod.sh

# Utilities
fmt:
	terraform fmt -recursive

validate:
	terraform validate

help:
	@echo "Local stack (solo dev — slug '$(LEGACY_SLUG)'; for parallel sessions use scripts/wt-up.sh):"
	@echo "  make shared-up                    start the shared services stack only (machine-wide)"
	@echo "  make shared-down [PURGE=1]        stop the shared stack (PURGE=1 also deletes its volumes)"
	@echo "  make local-up                     shared + this slug's app services (DB/vhost/buckets + migrate)"
	@echo "  make local-up-fg                  app services in foreground (streams logs)"
	@echo "  make local-up SERVICE=backend     provision, then (re)build only one app service"
	@echo "  make local-down                   stop this slug's app stack (keeps shared + data)"
	@echo "  make local-purge                  stop + destroy this slug's DB/redis/vhost/buckets"
	@echo "  make local-restart [SERVICE=x]    restart all or one app service"
	@echo ""
	@echo "Debugging:"
	@echo "  make local-logs [SERVICE=x] [TAIL=500]   follow logs"
	@echo "  make local-tail [SERVICE=x] [TAIL=500]   print last N log lines and exit"
	@echo "  make local-ps                            list containers"
	@echo "  make local-health                        show service health"
	@echo "  make local-stats                         live CPU/mem/io usage"
	@echo "  make local-shell SERVICE=backend         open a shell in a container"
	@echo "  make local-exec SERVICE=backend CMD=\"...\"  run a one-off command"
	@echo "  make local-debug [SERVICE=x]             foreground + verbose log levels"
	@echo ""
	@echo "Analytics (Metabase read layer — run 'make shared-up' first):"
	@echo "  make analytics-up                start Metabase overlay (http://localhost:3001)"
	@echo "  make analytics-role              create/refresh the read-only metabase_ro DB role"
	@echo "  make analytics-down              stop and remove only the Metabase containers"
	@echo "  make analytics-test              e2e-test the read layer (funnels + read-only role)"
	@echo "  make analytics-connect-prod      read-only psql to the PRODUCTION DB as metabase_ro"
	@echo "  make analytics-logs [TAIL=500]   follow Metabase logs"
	@echo "  make analytics-ps                list Metabase containers"
	@echo ""
	@echo "Environment seeding:"
	@echo "  make seed                        seed the local stack to its known baseline"
	@echo "  make seed-env ENV=staging        seed a deployed environment via SSM"
	@echo ""
	@echo "Production deploy (authoritative — AXI-1349):"
	@echo "  make deploy-prod ENV=production TAG=<sha>            advance :stable + roll + migrate + health-check"
	@echo "  make deploy-prod ENV=production TAG=<sha> DRY_RUN=1  print the plan, mutate nothing"
