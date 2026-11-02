# 이미지는 digest 로만 배포한다(echo-was 계약). 태그는 덮어쓰지 못하게 한다.
# 도쿄 ECR 의 사본: 빌드 파이프라인이 같은 digest 를 여기에도 넣는다 (docs/architecture.md §4, GCP 는 ECR 에서 받지 않는다).
resource "google_artifact_registry_repository" "this" {
  location      = var.region
  repository_id = var.project
  description   = "Team Echo 컨테이너 이미지 (ECR echo/* 사본)"
  format        = "DOCKER"

  docker_config {
    immutable_tags = true
  }

  depends_on = [google_project_service.this["artifactregistry.googleapis.com"]]
}
