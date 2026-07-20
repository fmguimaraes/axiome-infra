terraform {
  backend "s3" {
    # Configure via -backend-config=../environments/shared/backend.hcl
    # Required keys:
    #   bucket         = "axiome-shared-tfstate"
    #   key            = "infrastructure/terraform.tfstate"
    #   region         = "eu-west-3"
    #   dynamodb_table = "axiome-shared-tflock"
    #   encrypt        = true
    #
    # The state bucket and lock table are created once per AWS account by
    # `../bootstrap/` (var.environments includes "shared"), same as dev/staging/production.
  }
}
