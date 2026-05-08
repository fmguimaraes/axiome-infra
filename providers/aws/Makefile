.PHONY: bootstrap init plan apply destroy fmt validate output ssh

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
