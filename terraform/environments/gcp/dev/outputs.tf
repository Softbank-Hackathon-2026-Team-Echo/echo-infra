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
