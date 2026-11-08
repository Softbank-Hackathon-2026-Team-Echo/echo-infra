mock_provider "google" {}
variables {
  project_id = "echo-security-test"
}
run "disabled_by_default" {
  command = plan
  assert {
    condition     = length(google_service_account.security_reader) == 0 && length(google_project_iam_member.security_reader) == 0
    error_message = "Reader provisioning must be opt-in."
  }
}
run "dedicated_workload" {
  command = plan
  variables {
    security_reader_enabled = true
  }
  assert {
    condition     = google_service_account_iam_member.security_reader_workload[0].member == "serviceAccount:echo-security-test.svc.id.goog[echo-security/security-reader]"
    error_message = "Only the dedicated collector KSA may use the reader GSA."
  }
  assert {
    condition     = google_project_iam_custom_role.security_reader[0].permissions == toset(["container.clusters.get", "resourcemanager.projects.get", "resourcemanager.projects.getIamPolicy", "iam.roles.get"])
    error_message = "Do not grant executor, credential or secret access."
  }
}
