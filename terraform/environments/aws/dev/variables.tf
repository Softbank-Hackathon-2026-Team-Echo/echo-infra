variable "project" {
  description = "리소스 이름 접두어와 project 태그 값"
  type        = string
  default     = "echo"
}

variable "environment" {
  description = "env 태그와 이름에 쓰는 단계"
  type        = string
  default     = "dev"
}

variable "region" {
  description = "AWS 리전. 11/1 회의: AWS 일본 리전 → GCP 서울"
  type        = string
  default     = "ap-northeast-1"
}

# 네트워크

variable "vpc_cidr" {
  description = "VPC CIDR. GCP 서울·온프레 K3s 대역과 겹치면 안 된다 (표: contracts/aws-outputs.md)"
  type        = string
  default     = "10.50.0.0/16"
}

variable "availability_zones" {
  description = "서브넷을 둘 AZ 두 개"
  type        = list(string)
  default     = ["ap-northeast-1a", "ap-northeast-1c"]

  validation {
    condition     = length(var.availability_zones) == 2
    error_message = "AZ 는 두 개만 쓴다."
  }
}

# EKS

variable "eks_version" {
  description = "EKS 쿠버네티스 버전. 본선 기간에는 올리지 않는다"
  type        = string
  default     = "1.35"
}

variable "eks_public_access_cidrs" {
  description = "EKS API 공개 엔드포인트에 붙을 수 있는 CIDR. 인증은 IAM 이 따로 한다. 장소가 정해지면 좁힌다"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "eks_admin_principal_arns" {
  description = "EKS 클러스터 관리자 접근을 줄 IAM 사용자·역할 ARN (Access Entry)"
  type        = list(string)
  default     = []
}

variable "node_instance_types" {
  description = "관리형 노드 그룹 인스턴스 타입. 계정이 AWS 무료 플랜이라 free-tier-eligible 타입만 뜬다 (t3.large 는 RunInstances 거부)"
  type        = list(string)
  default     = ["m7i-flex.large"]
}

variable "node_desired_size" {
  type    = number
  default = 2
}

variable "node_min_size" {
  type    = number
  default = 2
}

variable "node_max_size" {
  type    = number
  default = 3
}

# ECR

variable "ecr_repositories" {
  description = "만들 ECR 저장소 이름 (echo/<이름>)"
  type        = list(string)
  default     = ["app"]
}

# 비용 알림

variable "budget_limit_usd" {
  description = "월 비용 알림 금액(USD). NFR-13 ₩500,000 을 AWS·GCP 로 어떻게 나눌지는 팀 결정"
  type        = number
  default     = 150
}

variable "budget_notification_emails" {
  description = "비용 알림을 받을 메일. 비어 있으면 Terraform 예산을 만들지 않는다(콘솔 예산 알림을 쓴다)"
  type        = list(string)
  default     = []
}

# CI

# GitHub 저장소 목록은 terraform/modules/github-repos 가 단일 출처다 (GCP 루트와 공유).

# 배포 실행기 (GKE 위 echo-was 일꾼 → EKS)

variable "executor_google_service_account_id" {
  description = "echo-was 관제탑 GSA 의 uniqueId (GCP 루트 출력값 control_plane_service_account_unique_id). GCP 루트를 먼저 apply 한다"
  type        = string

  validation {
    condition     = can(regex("^[0-9]{10,}$", var.executor_google_service_account_id))
    error_message = "GSA 의 uniqueId(숫자)를 넣는다. 이메일이 아니다."
  }
}
