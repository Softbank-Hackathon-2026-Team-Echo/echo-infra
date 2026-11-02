# 이름은 contracts/aws-outputs.md 가 단일 출처다.

output "region" {
  value = var.region
}

output "eks_cluster_name" {
  value = aws_eks_cluster.this.name
}

output "eks_cluster_endpoint" {
  value = aws_eks_cluster.this.endpoint
}

output "vpc_id" {
  value = aws_vpc.this.id
}

output "vpc_cidr" {
  value = aws_vpc.this.cidr_block
}

output "private_subnet_ids" {
  value = [for s in aws_subnet.private : s.id]
}

output "ecr_repository_urls" {
  value = { for k, r in aws_ecr_repository.this : k => r.repository_url }
}

output "ci_plan_role_arn" {
  description = "GitHub Actions 의 aws-actions/configure-aws-credentials role-to-assume"
  value       = aws_iam_role.ci_plan.arn
}
