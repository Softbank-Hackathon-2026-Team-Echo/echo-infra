# VM 서비스 계정: 프로젝트 역할 0개. 아래 비밀 4개를 읽는 권한만 비밀 단위로 준다.
# 그래서 VM 이 털려도 이 프로젝트의 다른 리소스(GKE·DB·다른 비밀)에 닿지 못한다.
resource "google_service_account" "runner" {
  account_id   = "${local.name}-runner"
  display_name = "AI 에이전트 샌드박스 VM (${local.name}, 프로젝트 역할 없음)"
}

# 비밀 껍데기만 만든다. 값(version)은 사람이 넣는다(test-database-url 만 testdb.tf) → 저장소·state 에 값 0건.
#   gcloud secrets versions add <secret_id> --data-file=-
#   anthropic-api-key : 제어 프로세스가 Claude API 를 부를 키
#   was-runner-token  : echo-was 에서 실행을 가져가는 러너 토큰(WAS ↔ 러너 계약)
#   was-agent-token   : echo-was 를 읽기만 하는 에이전트 토큰(짧은 만료)
#   test-database-url : AI 수정안 검증용 테스트 DB 접속 문자열(값은 testdb.tf 가 apply 때 write-only 로 넣는다)
locals {
  secret_names = ["anthropic-api-key", "was-runner-token", "was-agent-token", "test-database-url"]
}

resource "google_secret_manager_secret" "runner" {
  for_each  = toset(local.secret_names)
  secret_id = "${local.name}-${each.value}"

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_iam_member" "runner_accessor" {
  for_each  = google_secret_manager_secret.runner
  secret_id = each.value.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.runner.email}"
}
