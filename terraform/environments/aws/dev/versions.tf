terraform {
  required_version = "~> 1.16.0"

  # 값은 backend.hcl (커밋하지 않음, backend.hcl.example 참고)
  backend "s3" {}

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.67.0"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      project    = var.project
      env        = var.environment
      managed-by = "terraform"
      repo       = "echo-infra"
    }
  }
}

# 진입점 c (인프라 17, entrypoint-c.tf) 만 쓰는 서울 리전. 이 루트의 나머지는 위 기본 provider(도쿄)다.
# 도쿄는 재난 시나리오 리전이라 입구를 두지 않는다 — 입구는 서울 안에서 GCP(a·b)와 AWS(c) 두 회사로.
provider "aws" {
  alias  = "seoul"
  region = var.entrypoint_c_region

  default_tags {
    tags = {
      project    = var.project
      env        = var.environment
      managed-by = "terraform"
      repo       = "echo-infra"
    }
  }
}
