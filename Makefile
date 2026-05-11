.PHONY: init plan apply destroy local-up local-down local-restart

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

local-up:
	$(DOCKER_COMPOSE) -f docker-compose.yml up -d

local-down:
	$(DOCKER_COMPOSE) -f docker-compose.yml down

local-restart:
	$(DOCKER_COMPOSE) -f docker-compose.yml down && $(DOCKER_COMPOSE) -f docker-compose.yml up -d

local-logs:
	$(DOCKER_COMPOSE) -f docker-compose.yml logs -f

# Utilities
fmt:
	terraform fmt -recursive

validate:
	terraform validate
