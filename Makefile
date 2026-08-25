.PHONY: init plan apply destroy \
        local-up local-up-fg local-down local-restart \
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

# Local development
#
# docker-compose.override.yml (or docker-compose.*.override.yml, gitignored,
# machine-local) is auto-merged when present: point a service's `volumes:` at
# a `_worktrees/<repo>-<branch>` checkout instead of the primary checkout to
# develop against worktree content in the dockerized stack. See
# docker-compose.override.yml.example.
DOCKER_COMPOSE  := $(shell docker compose version >/dev/null 2>&1 && echo "docker compose" || echo "docker-compose")
COMPOSE_FILE    := docker-compose.yml
COMPOSE_OVERRIDE := $(wildcard docker-compose.override.yml)
COMPOSE         := $(DOCKER_COMPOSE) -f $(COMPOSE_FILE) $(if $(COMPOSE_OVERRIDE),-f $(COMPOSE_OVERRIDE))

# Behavior Tracking read layer (Metabase over the deployment DB — AXI-1048).
# Overlay on the base stack; shares the axiome-local network + Postgres. The base
# stack must be up first (`make local-up`) since the network is created there.
ANALYTICS_FILE    := analytics/docker-compose.analytics.yml
ANALYTICS_COMPOSE := $(COMPOSE) -f $(ANALYTICS_FILE)
METABASE_SERVICES := metabase-db-init metabase

# Optional args:
#   SERVICE=<name>   limit a target to one service (backend, biocompute, frontend, postgres, ...)
#   TAIL=<n>         number of log lines to show (default 200)
#   CMD="..."        command to run inside the container (for local-exec)
SERVICE ?=
TAIL    ?= 200

local-up:
	$(COMPOSE) up -d $(SERVICE)

# Foreground mode: streams all logs live; Ctrl-C stops the stack.
local-up-fg:
	$(COMPOSE) up $(SERVICE)

local-down:
	$(COMPOSE) down

local-restart:
	$(COMPOSE) restart $(SERVICE)

# Follow logs (all services, or one with SERVICE=<name>).
local-logs:
	$(COMPOSE) logs -f --tail=$(TAIL) $(SERVICE)

# Print last N lines and exit (non-following). Useful for CI / scripts.
local-tail:
	$(COMPOSE) logs --tail=$(TAIL) $(SERVICE)

# Show running containers and their state.
local-ps:
	$(COMPOSE) ps

# Live resource usage (CPU / mem / net / io) for running containers.
local-stats:
	docker stats

# Print healthcheck status for every service that defines one.
local-health:
	$(COMPOSE) ps --format 'table {{.Name}}\t{{.State}}\t{{.Status}}'

# Open an interactive shell inside a service container.
# Usage: make local-shell SERVICE=backend
local-shell:
	@if [ -z "$(SERVICE)" ]; then \
		echo "Usage: make local-shell SERVICE=<service-name>"; exit 1; \
	fi
	$(COMPOSE) exec $(SERVICE) sh

# Run an arbitrary command inside a service container.
# Usage: make local-exec SERVICE=backend CMD="npm test"
local-exec:
	@if [ -z "$(SERVICE)" ] || [ -z "$(CMD)" ]; then \
		echo 'Usage: make local-exec SERVICE=<name> CMD="<command>"'; exit 1; \
	fi
	$(COMPOSE) exec $(SERVICE) sh -c '$(CMD)'

# Bring the stack up in the foreground with verbose application logging.
# Overrides LOG_LEVEL / DEBUG flags for the duration of the run only.
local-debug:
	BIOCOMPUTE_LOG_LEVEL=DEBUG \
	LOG_LEVEL=debug \
	NODE_OPTIONS=--enable-source-maps \
	DEBUG=$${DEBUG:-axiome:*} \
	PYTHONUNBUFFERED=1 \
	$(COMPOSE) up $(SERVICE)

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
	$(COMPOSE) exec -T postgres psql -U $${POSTGRES_USER:-axiome} -d $${POSTGRES_DB:-axiome} \
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
	scripts/seed-environment.sh --local

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
	@echo "Local stack:"
	@echo "  make local-up                     start all services detached"
	@echo "  make local-up-fg                  start all services in foreground (streams logs)"
	@echo "  make local-up SERVICE=backend     start only one service"
	@echo "  make local-down                   stop and remove containers"
	@echo "  make local-restart [SERVICE=x]    restart all or one service"
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
	@echo "Analytics (Metabase read layer — run 'make local-up' first):"
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
