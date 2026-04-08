terraform {
  backend "s3" {
    # Scaleway Object Storage is S3-compatible
    # Configure via environment variables or backend config file:
    #   -backend-config=environments/<env>/backend.hcl
    #
    # Required backend config:
    #   bucket         = "axiome-<env>-terraform-state"
    #   key            = "infrastructure/terraform.tfstate"
    #   region         = "fr-par"
    #   endpoints      = { s3 = "https://s3.fr-par.scw.cloud" }
    #   skip_credentials_validation = true
    #   skip_region_validation      = true
    #   skip_requesting_account_id  = true
    #   skip_metadata_api_check     = true
    #   skip_s3_checksum            = true
  }
}
