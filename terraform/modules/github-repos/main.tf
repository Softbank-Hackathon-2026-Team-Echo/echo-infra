# GitHub 저장소 목록. provider 없이 값만 낸다. AWS·GCP 루트가 같은 목록을 읽어 "한쪽만 허용" 드리프트를 막는다.
# 저장소를 더하면 두 루트를 모두 plan·apply 한다.
locals {
  plan_repository = "Softbank-Hackathon-2026-Team-Echo/echo-infra"
  build_repositories = [
    "Softbank-Hackathon-2026-Team-Echo/echo-was",
  ]
}

output "plan_repository" {
  description = "Terraform plan 용 역할(읽기 전용)을 받는 저장소 (owner/name). main 브랜치와 PR"
  value       = local.plan_repository
}

output "build_repositories" {
  description = "빌드 실행기 역할(ECR·AR push)을 받는 저장소 (owner/name). main 브랜치만"
  value       = local.build_repositories
}
