terraform {
  backend "s3" {
    # OVH Object Storage (High Performance) is S3-compatible. Configure via:
    #   -backend-config=environments/<env>/backend.hcl
    # Required keys:
    #   bucket                      = "axiome-<env>-tfstate"
    #   key                         = "infrastructure/terraform.tfstate"
    #   region                      = "gra"
    #   endpoints                   = { s3 = "https://s3.gra.io.cloud.ovh.net" }
    #   skip_credentials_validation = true
    #   skip_region_validation      = true
    #   skip_requesting_account_id  = true
    #   skip_metadata_api_check     = true
    #   skip_s3_checksum            = true
    #
    # AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY env vars must be set to the OVH
    # Object Storage (S3) access keys for state operations.
  }
}
