# AI #27: controller-side Trivy reads pinned customer images through the attached SA.
# This repository-scoped role grants no upload or cluster access. No service-account key.
variable "customer_image_repository" {
  description = "Optional GAR repository for customer SBOM and CVE baseline scans"
  type = object({
    project    = string
    location   = string
    repository = string
  })
  default  = null
  nullable = true
}

resource "google_artifact_registry_repository_iam_member" "runner_customer_image_reader" {
  count      = var.customer_image_repository == null ? 0 : 1
  project    = var.customer_image_repository.project
  location   = var.customer_image_repository.location
  repository = var.customer_image_repository.repository
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:${google_service_account.runner.email}"
}
