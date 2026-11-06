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

output "cutover_role_arn" {
  description = "컷오버 Job 이 받는 AWS 역할. 컷오버 이미지 빌드 인자 AWS_ROLE_ARN (replication/cutover-job/README.md). cutover_google_service_account_id 가 비면 null"
  value       = try(aws_iam_role.cutover[0].arn, null)
}

# 진입점 c (인프라 17). entrypoint_c_enabled = false 면 null.
output "entrypoint_c_ip" {
  description = "AWS 서울 진입점 c 의 고정 공인 IP. Cloudflare LB 풀 2 엔드포인트, 닻 ALB inbound-cidrs, GKE 외부 LB loadBalancerSourceRanges, GCP entrypoint_weights_sync_cidrs 에 /32 로 넣는다"
  value       = try(aws_eip.entry_c[0].public_ip, null)
}

output "entrypoint_c_instance_id" {
  description = "진입점 c EC2 ID. 접속: aws ssm start-session --region ap-northeast-2 --target <이 값>"
  value       = try(aws_instance.entry_c[0].id, null)
}

output "entrypoint_c_config_bucket" {
  description = "진입점 c 설정 버킷(entrypoint/ 파일 + settings.env). 비밀값 없음"
  value       = try(aws_s3_bucket.entry_c[0].id, null)
}
