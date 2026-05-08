terraform {
  backend "s3" {
    # Configure via -backend-config=environments/<env>/backend.hcl
    # Required keys:
    #   bucket         = "axiome-<env>-tfstate"
    #   key            = "infrastructure/terraform.tfstate"
    #   region         = "eu-west-3"
    #   dynamodb_table = "axiome-<env>-tflock"
    #   encrypt        = true
    #
    # The state bucket and lock table are created once per AWS account by
    # `bootstrap/` (run with local state, then re-init root with this backend).
  }
}
