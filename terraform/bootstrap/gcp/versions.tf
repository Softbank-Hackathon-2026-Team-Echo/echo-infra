terraform {
  required_version = "~> 1.16.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 8.9.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region

  default_labels = {
    project    = var.project
    managed-by = "terraform"
    repo       = "echo-infra"
  }
}
