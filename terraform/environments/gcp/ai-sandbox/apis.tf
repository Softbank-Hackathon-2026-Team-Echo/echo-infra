# compute·iam·secretmanager API 는 gcp/dev 루트가 켜 두었다(같은 프로젝트). 이 루트는 다시 관리하지 않는다.
# IAP 터널(SSH)만 여기서 켠다. 이 루트를 지워도 API 는 끄지 않는다(다른 루트가 쓸 수 있다).
resource "google_project_service" "iap" {
  service            = "iap.googleapis.com"
  disable_on_destroy = false
}
