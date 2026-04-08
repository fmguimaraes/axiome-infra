# AWS Provider

AWS provider modules are structured to mirror the Scaleway module interface. When switching providers, replace the module source paths in `main.tf` to point to these AWS-specific implementations.

## Status
Not yet implemented. The Scaleway provider is the primary target for Phase 1.

## Module Interface Contract
Each AWS module must expose the same input variables and outputs as its Scaleway counterpart:
- `modules/network` -> `providers/aws/network`
- `modules/compute` -> `providers/aws/compute`
- `modules/database` -> `providers/aws/database`
- `modules/storage` -> `providers/aws/storage`
- `modules/secrets` -> `providers/aws/secrets`
- `modules/registry` -> `providers/aws/registry`

## Switching Providers
1. Copy the environment tfvars and update provider-specific values (region, node types)
2. Update `main.tf` module source paths to use `providers/aws/<module>`
3. Update `versions.tf` to require the AWS provider
4. Run `terraform init` and `terraform plan`
