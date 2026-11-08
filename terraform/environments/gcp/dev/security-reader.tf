# Opt-in independent collector workload. No secret access, impersonation or app mutation.
variable "security_reader_enabled" {
  type        = bool
  default     = false
  description = "Provision a separate environment security collector identity"
}
resource "google_service_account" "security_reader" {
  count        = var.security_reader_enabled ? 1 : 0
  account_id   = "${local.name}-security-reader"
  display_name = "Environment security reader"
  depends_on   = [google_project_service.this["iam.googleapis.com"]]
}
resource "google_project_iam_custom_role" "security_reader" {
  count       = var.security_reader_enabled ? 1 : 0
  role_id     = "echoEnvironmentSecurityReader"
  title       = "Environment security metadata reader"
  permissions = ["container.clusters.get", "resourcemanager.projects.get", "resourcemanager.projects.getIamPolicy", "iam.roles.get"]
}
resource "google_project_iam_member" "security_reader" {
  count   = var.security_reader_enabled ? 1 : 0
  project = var.project_id
  role    = google_project_iam_custom_role.security_reader[0].name
  member  = "serviceAccount:${google_service_account.security_reader[0].email}"
}
resource "google_service_account_iam_member" "security_reader_workload" {
  count              = var.security_reader_enabled ? 1 : 0
  service_account_id = google_service_account.security_reader[0].name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[echo-security/security-reader]"
}
output "security_reader_identity" {
  value = var.security_reader_enabled ? {
    email     = google_service_account.security_reader[0].email
    unique_id = google_service_account.security_reader[0].unique_id
  } : null
}
