terraform {
  required_version = "~> 1.16.0"

  # 값은 backend.hcl (커밋하지 않음, backend.hcl.example 참고). gcp/dev 와 같은 버킷, 다른 prefix.
  backend "gcs" {}

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 8.9.0"
    }
    # 테스트 DB 비밀번호(ephemeral, state 에 남지 않음)
    random = {
      source  = "hashicorp/random"
      version = "~> 3.7"
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
