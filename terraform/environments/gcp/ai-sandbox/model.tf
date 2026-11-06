# 서울 리전 Claude(Vertex AI) 호출 권한 (11/6 회의: "GCP 샌드박스에서 서울 리전 Claude 로 코드 수정·시험").
# 러너는 Anthropic API 키 대신 Vertex AI(asia-northeast3) 로 부를 수 있다 → 고객 코드·로그가 서울 리전 밖으로 나가지 않는다.
# VM SA 에는 모델 호출(predict) 권한 하나만 담은 커스텀 역할을 준다(D-5: 기본·사전 정의 역할 없음).
# Model Garden 에서 Claude 사용 동의(약관)는 콘솔에서 사람이 한 번 한다(Terraform 대상 아님).
resource "google_project_service" "aiplatform" {
  service            = "aiplatform.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_iam_custom_role" "model_invoker" {
  role_id     = "echoSandboxModelInvoker"
  title       = "Echo 샌드박스 모델 호출"
  description = "AI 샌드박스 VM 이 Vertex AI 의 Claude 를 부르는 권한만(predict). 엔드포인트·모델 만들기·지우기 없음"
  permissions = ["aiplatform.endpoints.predict"]
}

resource "google_project_iam_member" "runner_model_invoker" {
  project = var.project_id
  role    = google_project_iam_custom_role.model_invoker.id
  member  = "serviceAccount:${google_service_account.runner.email}"
}
