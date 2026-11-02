# GitHub Actions 가 장기 키 없이 plan 만 돌리는 서비스 계정 (Workload Identity 연합). AWS 의 ci_plan 역할과 같은 모양.
# main 브랜치와 PR 에서만 받는다.
resource "google_iam_workload_identity_pool" "github" {
  workload_identity_pool_id = "${local.name}-github"
  display_name              = "GitHub Actions (${local.name})"

  depends_on = [google_project_service.this["iam.googleapis.com"]]
}

resource "google_iam_workload_identity_pool_provider" "github" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "github"
  display_name                       = "GitHub OIDC"

  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.repository" = "assertion.repository"
  }

  # plan 저장소(main·PR)와 빌드 저장소(main)만 통과한다. 저장소별 권한은 아래 SA 바인딩이 가른다.
  attribute_condition = "assertion.repository in ${jsonencode(distinct(concat([var.github_repository], var.ci_build_repositories)))} && (assertion.ref == \"refs/heads/main\" || assertion.ref.startsWith(\"refs/pull/\"))"

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

resource "google_service_account" "ci_plan" {
  account_id   = "${local.name}-ci-plan"
  display_name = "CI plan (${local.name})"

  depends_on = [
    google_project_service.this["iam.googleapis.com"],
    google_project_service.this["cloudresourcemanager.googleapis.com"],
  ]
}

resource "google_project_iam_member" "ci_plan_viewer" {
  project = var.project_id
  role    = "roles/viewer"
  member  = "serviceAccount:${google_service_account.ci_plan.email}"

  depends_on = [google_project_service.this["cloudresourcemanager.googleapis.com"]]
}

resource "google_service_account_iam_member" "ci_plan_wif" {
  service_account_id = google_service_account.ci_plan.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.repository/${var.github_repository}"
}

# ---------- 빌드 실행기: GitHub Actions → Artifact Registry push ----------
# AWS 의 ci_build 역할과 짝. 같은 digest 를 ECR 과 여기에 넣는다 (GKE 는 ECR 을 보지 않는다).
resource "google_service_account" "ci_build" {
  account_id   = "${local.name}-ci-build"
  display_name = "CI build (${local.name})"

  depends_on = [
    google_project_service.this["iam.googleapis.com"],
    google_project_service.this["cloudresourcemanager.googleapis.com"],
  ]
}

resource "google_artifact_registry_repository_iam_member" "ci_build_writer" {
  location   = google_artifact_registry_repository.this.location
  repository = google_artifact_registry_repository.this.name
  role       = "roles/artifactregistry.writer"
  member     = "serviceAccount:${google_service_account.ci_build.email}"
}

resource "google_service_account_iam_member" "ci_build_wif" {
  for_each           = toset(var.ci_build_repositories)
  service_account_id = google_service_account.ci_build.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.repository/${each.value}"
}

# ---------- 배포 실행기: echo-was 일꾼(관제탑 GSA) → GKE ----------
# 일꾼은 Workload Identity 로 관제탑 GSA(control-plane.tf)가 되고, 이 권한으로 GKE 에 고객 앱을 올린다.
# EKS 쪽은 같은 GSA 의 Google ID 토큰으로 AWS executor 역할을 받는다 (aws 루트 ci.tf).
resource "google_project_iam_member" "executor_gke" {
  project = var.project_id
  role    = "roles/container.developer"
  member  = "serviceAccount:${google_service_account.control_plane.email}"

  depends_on = [google_project_service.this["cloudresourcemanager.googleapis.com"]]
}
