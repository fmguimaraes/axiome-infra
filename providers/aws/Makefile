.PHONY: bootstrap init plan apply destroy fmt validate output ssh \
        power-status power-up power-down data-status data-down data-up

ENV ?= dev

# Initialize Terraform with the env-specific backend
init:
	terraform init -backend-config=environments/$(ENV)/backend.hcl -reconfigure

# One-time per-env bootstrap: creates state bucket + lock table.
# Run this with local state before `make init` for that environment.
bootstrap:
	cd bootstrap && terraform init && terraform apply -var=environment=$(ENV)

plan:
	terraform plan \
	    -var-file=environments/$(ENV)/terraform.tfvars \
	    -var-file=environments/$(ENV)/images.tfvars

apply:
	terraform apply \
	    -var-file=environments/$(ENV)/terraform.tfvars \
	    -var-file=environments/$(ENV)/images.tfvars

destroy:
	terraform destroy \
	    -var-file=environments/$(ENV)/terraform.tfvars \
	    -var-file=environments/$(ENV)/images.tfvars

output:
	terraform output

# Convenience: SSH into the Lightsail instance via AWS CLI
ssh:
	@aws lightsail get-instance-access-details \
	    --instance-name "$$(terraform output -raw lightsail_instance_name)" \
	    --region "$$(terraform output -raw aws_region 2>/dev/null || echo eu-west-3)" \
	    --query 'accessDetails.[ipAddress,username]' --output text

fmt:
	terraform fmt -recursive

validate:
	terraform validate

# --- Cost power controls (ENV=production required for prod) --------------------
# Compute on/off (safe, daily). Never touches storage. See docs/power-runbook.md.
power-status:
	@scripts/power.sh $(ENV) status
power-up:
	@scripts/power.sh $(ENV) up
power-down:
	@scripts/power.sh $(ENV) down

# Data-tier park (long idle only; destructive for ElastiCache). Gate terraform-cd
# for the whole down->up window. See docs/power-runbook.md.
data-status:
	@scripts/power-data.sh $(ENV) status
data-down:
	@scripts/power-data.sh $(ENV) down
data-up:
	@scripts/power-data.sh $(ENV) up
