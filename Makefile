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
local-up:
	docker compose -f docker-compose.yml up -d

local-down:
	docker compose -f docker-compose.yml down

local-restart:
	docker compose -f docker-compose.yml down && docker compose -f docker-compose.yml up -d

local-logs:
	docker compose -f docker-compose.yml logs -f

# Utilities
fmt:
	terraform fmt -recursive

validate:
	terraform validate
