# Only the dedicated GSA can obtain this role. No executor fallback.
variable "security_reader_google_service_account_id" {
  type        = string
  default     = ""
  description = "Dedicated collector GSA numeric unique ID; empty leaves resources disabled"
  validation {
    condition     = var.security_reader_google_service_account_id == "" || (can(regex("^[0-9]{10,30}$", var.security_reader_google_service_account_id)) && var.security_reader_google_service_account_id != var.executor_google_service_account_id && var.security_reader_google_service_account_id != var.cutover_google_service_account_id)
    error_message = "Use the dedicated GSA numeric unique ID."
  }
}
variable "security_reader_targets" {
  type = object({
    role_arns         = set(string)
    policy_arns       = set(string)
    access_entry_arns = set(string)
  })
  default     = { role_arns = [], policy_arns = [], access_entry_arns = [] }
  description = "Exact audited IAM role, policy and EKS access-entry ARNs; no wildcards"
  validation {
    condition = alltrue(concat(
      [for arn in var.security_reader_targets.role_arns : can(regex("^arn:aws:iam::[0-9]{12}:role/[^*?]+$", arn))],
      [for arn in var.security_reader_targets.policy_arns : can(regex("^arn:aws:iam::([0-9]{12}|aws):policy/[^*?]+$", arn))],
      [for arn in var.security_reader_targets.access_entry_arns : can(regex("^arn:aws:eks:[a-z0-9-]+:[0-9]{12}:access-entry/[^*?]+$", arn))]
    ))
    error_message = "Reader targets must be exact ARNs of the expected resource type."
  }
}
locals {
  security_reader_enabled = var.security_reader_google_service_account_id != ""
  security_reader_statements = concat(
    [{ Effect = "Allow", Action = ["eks:DescribeCluster"], Resource = [aws_eks_cluster.this.arn] }],
    length(var.security_reader_targets.role_arns) > 0 ? [{
      Effect   = "Allow", Action = ["iam:GetRole", "iam:ListRolePolicies", "iam:GetRolePolicy", "iam:ListAttachedRolePolicies"],
      Resource = sort(tolist(var.security_reader_targets.role_arns))
    }] : [],
    length(var.security_reader_targets.policy_arns) > 0 ? [{
      Effect   = "Allow", Action = ["iam:GetPolicy", "iam:GetPolicyVersion"],
      Resource = sort(tolist(var.security_reader_targets.policy_arns))
    }] : [],
    length(var.security_reader_targets.access_entry_arns) > 0 ? [{
      Effect   = "Allow", Action = ["eks:DescribeAccessEntry", "eks:ListAssociatedAccessPolicies"],
      Resource = sort(tolist(var.security_reader_targets.access_entry_arns))
    }] : []
  )
}
resource "aws_iam_role" "security_reader" {
  count = local.security_reader_enabled ? 1 : 0
  name  = "${local.name}-security-reader"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow", Principal = { Federated = aws_iam_openid_connect_provider.google.arn },
      Action = "sts:AssumeRoleWithWebIdentity",
      Condition = { StringEquals = {
        "accounts.google.com:aud"  = var.security_reader_google_service_account_id
        "accounts.google.com:oaud" = "sts.amazonaws.com"
        "accounts.google.com:sub"  = var.security_reader_google_service_account_id
      } }
    }]
  })
}
resource "aws_iam_role_policy" "security_reader" {
  count  = local.security_reader_enabled ? 1 : 0
  role   = aws_iam_role.security_reader[0].id
  name   = "environment-security-read"
  policy = jsonencode({ Version = "2012-10-17", Statement = local.security_reader_statements })
}
resource "aws_eks_access_entry" "security_reader" {
  count             = local.security_reader_enabled ? 1 : 0
  cluster_name      = aws_eks_cluster.this.name
  principal_arn     = aws_iam_role.security_reader[0].arn
  kubernetes_groups = ["echo-security-reader"]
  type              = "STANDARD"
}
output "security_reader_role_arn" {
  value = local.security_reader_enabled ? aws_iam_role.security_reader[0].arn : null
}
