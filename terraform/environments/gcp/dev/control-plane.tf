# 관제탑(echo-was)용 GCP 기반. 실제 API·Worker·PostgreSQL Kubernetes 객체와
# 비밀값 version 은 API 담당이 배포한다. 이 파일은 GSA·Workload Identity·비밀값
# 껍데기·고정 IP·TLS 인증서만 제공해 앱 배포가 클라우드 콘솔 수작업에 의존하지 않게 한다.
locals {
  control_plane_name      = "${local.name}-echo-was"
  control_plane_namespace = "echo-was"
  control_plane_ksa       = "echo-was"

  # 값은 만들지 않는다. 담당자가 Secret Manager 에 version 을 추가한다.
  control_plane_secrets = {
    database_url             = "${local.control_plane_name}-database-url"
    github_app_private_key   = "${local.control_plane_name}-github-app-private-key"
    github_app_client_secret = "${local.control_plane_name}-github-app-client-secret"
  }
}

resource "google_service_account" "control_plane" {
  account_id   = local.control_plane_name
  display_name = "Echo control plane (${local.control_plane_name})"

  depends_on = [
    google_project_service.this["iam.googleapis.com"],
    google_project_service.this["cloudresourcemanager.googleapis.com"],
  ]
}

# API 담당이 같은 이름의 namespace·KSA 를 만들고 이 GSA 이메일로 annotation 한다.
resource "google_service_account_iam_member" "control_plane_workload_identity" {
  service_account_id = google_service_account.control_plane.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[${local.control_plane_namespace}/${local.control_plane_ksa}]"
}

resource "google_secret_manager_secret" "control_plane" {
  for_each  = local.control_plane_secrets
  secret_id = each.value

  replication {
    auto {}
  }

  depends_on = [google_project_service.this["secretmanager.googleapis.com"]]
}

# 프로젝트 전체 secretAccessor 대신 echo-was 전용 세 비밀에만 읽기 권한을 준다.
resource "google_secret_manager_secret_iam_member" "control_plane_accessor" {
  for_each  = google_secret_manager_secret.control_plane
  secret_id = each.value.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.control_plane.email}"
}

# 관제탑 일꾼이 고정 진입점 가중치 API(PUT /weights · GET /counters)를 부를 때 쓰는 토큰.
# 비밀 껍데기는 entrypoint.tf 가 만들고 값은 진입점 VM 이 넣는다. 관제탑은 읽기만 한다.
resource "google_secret_manager_secret_iam_member" "control_plane_entry_token" {
  secret_id = google_secret_manager_secret.entry["weights-token"].id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.control_plane.email}"
}

# api.echoport.uk 용 GKE 외부 Ingress 자원. Cloudflare DNS 레코드와 Kubernetes
# Ingress 는 앱 담당이 출력값을 받아 연결한다.
resource "google_compute_global_address" "control_plane" {
  name = local.control_plane_name

  depends_on = [google_project_service.this["compute.googleapis.com"]]
}

resource "google_compute_managed_ssl_certificate" "control_plane" {
  name = local.control_plane_name

  managed {
    domains = [var.control_plane_domain]
  }

  depends_on = [google_project_service.this["compute.googleapis.com"]]
}
