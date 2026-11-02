terraform {
  required_version = "~> 1.16.0"

  # 값은 backend.hcl (커밋하지 않음, backend.hcl.example 참고)
  backend "gcs" {}

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
  zone    = var.zone

  default_labels = {
    project    = var.project
    env        = var.environment
    managed-by = "terraform"
    repo       = "echo-infra"
  }
}
