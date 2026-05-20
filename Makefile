.PHONY: init plan apply destroy \
        local-up local-up-fg local-down local-restart \
        local-logs local-tail local-ps local-stats \
        local-shell local-exec local-debug local-health \
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
DOCKER_COMPOSE := $(shell docker compose version >/dev/null 2>&1 && echo "docker compose" || echo "docker-compose")
COMPOSE_FILE   := docker-compose.yml
COMPOSE        := $(DOCKER_COMPOSE) -f $(COMPOSE_FILE)

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
