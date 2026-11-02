output "state_bucket" {
  description = "다른 GCP 루트의 backend.hcl 에 넣는 bucket 값"
  value       = google_storage_bucket.state.name
}

output "region" {
  value = var.region
}
