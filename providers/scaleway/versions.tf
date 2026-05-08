terraform {
  required_version = ">= 1.5.0"

  required_providers {
    scaleway = {
      source  = "scaleway/scaleway"
      version = "~> 2.40"
    }
    neon = {
      source  = "kislerdm/neon"
      version = "~> 0.6"
    }
    mongodbatlas = {
      source  = "mongodb/mongodbatlas"
      version = "~> 1.18"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}
