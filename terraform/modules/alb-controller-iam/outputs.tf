output "role_arn" {
  description = "컨트롤러 IAM 역할 ARN"
  value       = aws_iam_role.this.arn
}

output "policy_arn" {
  description = "컨트롤러 권한 정책 ARN"
  value       = aws_iam_policy.this.arn
}
