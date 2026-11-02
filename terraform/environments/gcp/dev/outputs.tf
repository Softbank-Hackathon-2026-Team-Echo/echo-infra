# 이름은 contracts/gcp-outputs.md 가 단일 출처다.

output "project_id" {
  value = var.project_id
}

output "region" {
  value = var.region
}

output "zone" {
  value = var.zone
}

output "gke_cluster_name" {
  value = google_container_cluster.this.name
}

output "gke_cluster_endpoint" {
  value = "https://${google_container_cluster.this.endpoint}"
}

output "network_name" {
  value = google_compute_network.this.name
}

output "subnet_cidr" {
  value = google_compute_subnetwork.this.ip_cidr_range
}

output "pods_cidr" {
  value = var.pods_cidr
}

output "services_cidr" {
  value = var.services_cidr
}

output "nat_ip" {
  description = "노드·파드가 밖으로 나갈 때 쓰는 고정 IP. AWS 쪽 복제 허용 목록에 적는다"
  value       = google_compute_address.nat.address
}

output "artifact_registry_urls" {
  value = { for img in var.artifact_images : img => "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.this.repository_id}/${img}" }
}

output "ci_plan_service_account" {
  description = "GitHub Actions google-github-actions/auth 의 service_account"
  value       = google_service_account.ci_plan.email
}

output "ci_workload_identity_provider" {
  description = "GitHub Actions google-github-actions/auth 의 workload_identity_provider"
  value       = google_iam_workload_identity_pool_provider.github.name
}

# 고정 진입점

output "entrypoint_ip" {
  description = "Cloudflare 에서 *.echoport.uk 를 가리킬 고정 IP"
  value       = google_compute_address.entry.address
}

output "entrypoint_weights_url" {
  description = "echo-was 실행기가 부르는 가중치 API (Bearer 토큰: Secret Manager)"
  value       = "http://${google_compute_address.entry.address}:8080"
}

output "entrypoint_grafana_url" {
  value = "http://${google_compute_address.entry.address}:3000"
}

output "entrypoint_token_secret" {
  description = "gcloud secrets versions access latest --secret=<이 값>"
  value       = google_secret_manager_secret.entry["weights-token"].secret_id
}

# 관제탑 (echo-was)

output "control_plane_ip" {
  description = "Cloudflare api.echoport.uk A 레코드가 가리킬 GKE Ingress 고정 IP"
  value       = google_compute_global_address.control_plane.address
}

output "control_plane_certificate_name" {
  description = "GKE Ingress ingress.gcp.kubernetes.io/pre-shared-cert annotation 값"
  value       = google_compute_managed_ssl_certificate.control_plane.name
}

output "control_plane_service_account" {
  description = "echo-was KSA 가 Workload Identity 로 사용할 GSA 이메일"
  value       = google_service_account.control_plane.email
}

output "control_plane_kubernetes_identity" {
  description = "API 담당이 만들 namespace 와 Kubernetes ServiceAccount"
  value = {
    namespace       = local.control_plane_namespace
    service_account = local.control_plane_ksa
  }
}

output "control_plane_secret_ids" {
  description = "값을 추가한 뒤 SecretSync 로 echo-was 파드에 전달할 Secret Manager ID"
  value       = { for key, secret in google_secret_manager_secret.control_plane : key => secret.secret_id }
}
