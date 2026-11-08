mock_provider "aws" {}
mock_provider "aws" { alias = "seoul" }
variables {
  executor_google_service_account_id = "111111111111111111111"
}
run "disabled_by_default" {
  command = plan
  assert {
    condition     = length(aws_iam_role.security_reader) == 0 && length(aws_eks_access_entry.security_reader) == 0
    error_message = "Default rollout must not create a security reader."
  }
}
run "separate_reader" {
  command = plan
  variables {
    security_reader_google_service_account_id = "222222222222222222222"
    security_reader_targets = {
      role_arns         = ["arn:aws:iam::123456789012:role/executor"]
      policy_arns       = ["arn:aws:iam::123456789012:policy/executor"]
      access_entry_arns = ["arn:aws:eks:ap-northeast-1:123456789012:access-entry/example/role/123456789012/executor/test"]
    }
  }
  assert {
    condition     = length(aws_iam_role.security_reader) == 1 && aws_eks_access_entry.security_reader[0].kubernetes_groups == toset(["echo-security-reader"])
    error_message = "Reader must use only its independent Kubernetes group."
  }
  assert {
    condition     = alltrue([for s in local.security_reader_statements : alltrue([for a in s.Action : can(regex(":(Get|List|Describe)", a))])])
    error_message = "Reader must have only explicit metadata read actions."
  }
}
run "shared_identity_rejected" {
  command = plan
  variables {
    security_reader_google_service_account_id = "111111111111111111111"
  }
  expect_failures = [var.security_reader_google_service_account_id]
}
