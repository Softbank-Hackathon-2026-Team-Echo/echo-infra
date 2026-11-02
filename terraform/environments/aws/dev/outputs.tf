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
  description = "GitHub Actions 의 aws-actions/configure-aws-credentials role-to-assume (plan)"
  value       = aws_iam_role.ci_plan.arn
}

output "ci_build_role_arn" {
  description = "빌드 실행기(echo-was 저장소 GitHub Actions)가 ECR push 에 쓰는 role-to-assume"
  value       = aws_iam_role.ci_build.arn
}

output "executor_role_arn" {
  description = "배포 실행기(GKE 위 echo-was 일꾼)가 Google ID 토큰으로 받는 역할. EKS 접근용"
  value       = aws_iam_role.executor.arn
}
