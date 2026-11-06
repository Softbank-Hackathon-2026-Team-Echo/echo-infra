# 컷오버 Job 전용 신원 (인프라 12.2, echo-infra#67). 서울 GKE echo-ops 네임스페이스의 KSA echo-cutover 가 이 GSA 가 된다.
# GSA 의 쓰임은 Google ID 토큰 하나다: AWS 루트의 cutover 역할(aws/dev/cutover.tf)이 이 GSA 만 믿는다.
# B(GKE) 안 권한은 IAM 이 아니라 쿠버네티스 RBAC(replication/cutover-job/manifests)로 준다 → 프로젝트 역할을 붙이지 않는다.
locals {
  cutover_name      = "${local.name}-cutover"
  cutover_namespace = "echo-ops"
  cutover_ksa       = "echo-cutover"
}

resource "google_service_account" "cutover" {
  account_id   = local.cutover_name
  display_name = "DB cutover Job (echo-ops/echo-cutover)"
  description  = "컷오버 Job 의 Google ID 토큰용. 프로젝트 역할 없음, AWS cutover 역할만 이 신원을 믿는다"

  depends_on = [
    google_project_service.this["iam.googleapis.com"],
    google_project_service.this["cloudresourcemanager.googleapis.com"],
  ]
}

resource "google_service_account_iam_member" "cutover_workload_identity" {
  service_account_id = google_service_account.cutover.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[${local.cutover_namespace}/${local.cutover_ksa}]"
}
