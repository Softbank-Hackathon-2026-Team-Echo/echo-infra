# Terraform state 버킷(GCS). 관리자가 1회 로컬 state 로 적용하고, 이후 GCP 루트는 이 버킷을 backend 로 쓴다.
# 원칙(docs/architecture.md §5-1): 각 클라우드의 state 는 그 클라우드에 둔다. AWS state 사본도 여기에 둘 예정.
resource "google_project_service" "storage" {
  service            = "storage.googleapis.com"
  disable_on_destroy = false
}

locals {
  state_bucket = "${var.project}-tfstate-${var.project_id}"
}

resource "google_storage_bucket" "state" {
  name     = local.state_bucket
  location = upper(var.region)

  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false

  versioning {
    enabled = true
  }

  # 지우면 GCP 환경의 state 를 잃는다. 정말 지울 때는 이 줄을 먼저 뺀다.
  lifecycle {
    prevent_destroy = true
  }

  depends_on = [google_project_service.storage]
}
