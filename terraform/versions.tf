terraform {
  required_version = ">= 1.5.0"

  required_providers {
    null = {
      source  = "hashicorp/null"
      version = ">= 3.2.2"
    }
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = ">= 1.48.0"
    }
  }
}
