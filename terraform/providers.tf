# Provider + version pins for the ephemeral AI Agent Lab cluster.
#
# Local state is intentional: this stack is a throwaway lab that lives for
# hours, not weeks. Do NOT add a remote backend for a demo cluster.

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.36"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
}
