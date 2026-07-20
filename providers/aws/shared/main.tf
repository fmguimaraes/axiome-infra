# Account-shared AWS resources, owned by their own dedicated Terraform state —
# never by a per-environment (dev/staging/production) state. This is the FR8/AC8
# fix for the "dev owns account-shared ECR" gap: a stray dev apply/destroy can no
# longer touch these resources because dev's config no longer declares them.
#
# Only add resources here that are genuinely account-level and shared across every
# environment (today: ECR). Anything env-scoped belongs in the per-environment root
# (../main.tf).

locals {
  base_tags = merge(
    {
      Project     = var.project_name
      Environment = "shared"
      ManagedBy   = "terraform"
    },
    var.common_tags
  )
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = local.base_tags
  }
}

# ---------------- Registry (ECR) ----------------
# Account-shared across dev/staging/production. This is the ONLY Terraform root
# that ever creates these repositories — per-environment roots only read the
# registry URL / pull role via `terraform_remote_state` against this state.

module "registry" {
  source = "../modules/registry"

  create_repositories = true
  project_name        = var.project_name
  tags                = local.base_tags
}
