.PHONY: init plan apply destroy fmt validate output ssh bootstrap

ENV ?= dev

# One-time per-env state bucket creation. Scaleway doesn't have an equivalent
# of DynamoDB locking; state corruption risk exists if multiple operators apply
# concurrently. Use a CI mutex or apply-from-one-machine policy.
bootstrap:
	scw object bucket create name=axiome-$(ENV)-tfstate region=fr-par || true
	scw object bucket-versioning enable bucket=axiome-$(ENV)-tfstate region=fr-par || true

init:
	terraform init -backend-config=environments/$(ENV)/backend.hcl -reconfigure

plan:
	terraform plan -var-file=environments/$(ENV)/terraform.tfvars

apply:
	terraform apply -var-file=environments/$(ENV)/terraform.tfvars

destroy:
	terraform destroy -var-file=environments/$(ENV)/terraform.tfvars

output:
	terraform output

ssh:
	@echo "ssh root@$$(terraform output -raw public_ip)"

fmt:
	terraform fmt -recursive

validate:
	terraform validate
