variable "project_id" {
  description = "본선 GCP 프로젝트 ID"
  type        = string
}

variable "project" {
  description = "리소스 이름 접두어와 project 라벨 값"
  type        = string
  default     = "echo"
}

variable "environment" {
  description = "env 라벨과 이름에 쓰는 단계"
  type        = string
  default     = "dev"
}

variable "region" {
  description = "GCP 리전. 11/1 회의: AWS 일본 리전 → GCP 서울"
  type        = string
  default     = "asia-northeast3"
}

variable "zone" {
  description = "존(zonal) GKE 와 VM 을 두는 존. 비용 때문에 리전 클러스터를 쓰지 않는다"
  type        = string
  default     = "asia-northeast3-a"
}

# 네트워크 (대역 표: contracts/gcp-outputs.md. AWS 10.50/16, 온프레 K3s 10.42·10.43 과 겹치면 안 된다)

variable "subnet_cidr" {
  description = "노드 서브넷"
  type        = string
  default     = "10.60.0.0/20"
}

variable "pods_cidr" {
  description = "파드 보조 대역 (VPC 네이티브)"
  type        = string
  default     = "10.61.0.0/16"
}

variable "services_cidr" {
  description = "서비스 보조 대역"
  type        = string
  default     = "10.62.0.0/20"
}

variable "master_cidr" {
  description = "GKE 컨트롤 플레인 대역 (/28, 노드·파드와 겹치지 않게)"
  type        = string
  default     = "172.16.0.0/28"
}

# GKE

variable "gke_release_channel" {
  description = "GKE 릴리스 채널. 11/5 CVE-2026-98432(노드 커널) 수정 버전 1.36.5-gke.1982000 이 RAPID 에만 있어 RAPID 로 올렸다(보안 담당 적용). 본선 뒤 REGULAR 로 되돌릴지 정한다"
  type        = string
  default     = "RAPID"
}

variable "gke_public_access_cidrs" {
  description = "GKE API 공개 엔드포인트에 붙을 수 있는 CIDR. 인증은 IAM 이 따로 한다. 장소가 정해지면 좁힌다"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "gke_admin_members" {
  description = "클러스터 관리자 권한(roles/container.admin)을 줄 IAM 멤버 (예: user:name@gmail.com)"
  type        = list(string)
  default     = []
}

variable "node_machine_type" {
  description = "노드 머신 타입. Warm 대기 2대, 경계 시 Hot 으로 늘린다"
  type        = string
  default     = "e2-standard-2"
}

variable "node_min_count" {
  type    = number
  default = 2
}

variable "node_max_count" {
  type    = number
  default = 3
}

variable "node_disk_size_gb" {
  type    = number
  default = 50
}

# Artifact Registry

variable "artifact_images" {
  description = "이미지 이름 (저장소 echo 아래 경로). ECR 의 echo/<이름> 과 맞춘다"
  type        = list(string)
  default     = ["app"]
}

# 비용 알림

variable "billing_account" {
  description = "결제 계정 ID (XXXXXX-XXXXXX-XXXXXX). budget_notification_emails 가 있을 때만 필요하다"
  type        = string
  default     = ""

  validation {
    condition     = length(var.budget_notification_emails) == 0 || var.billing_account != ""
    error_message = "비용 알림 메일을 넣었으면 billing_account 도 넣어야 한다."
  }
}

variable "budget_limit_usd" {
  description = "월 비용 알림 금액(USD). NFR-13 ₩500,000 을 AWS·GCP 로 어떻게 나눌지는 팀 결정"
  type        = number
  default     = 150
}

variable "budget_notification_emails" {
  description = "비용 알림을 받을 메일. 비어 있으면 Terraform 예산을 만들지 않는다(콘솔 예산을 쓴다)"
  type        = list(string)
  default     = []
}

# CI

# GitHub 저장소 목록은 terraform/modules/github-repos 가 단일 출처다 (AWS 루트와 공유).

# 고정 진입점 (Envoy VM)

variable "entrypoint_machine_type" {
  description = "진입점 VM 머신 타입. Envoy·weights-api·Prometheus·Grafana 네 컨테이너"
  type        = string
  default     = "e2-small"
}

variable "entrypoint_upstreams" {
  description = "환경별 업스트림 host:port (AWS ALB, GKE 인그레이스). 순서는 환경 순서. 정해지기 전엔 placeholder"
  type        = map(string)
  default = {
    aws = "placeholder.invalid:80"
    gcp = "placeholder.invalid:80"
  }
}

variable "entrypoint_default_weights" {
  description = "저장된 가중치가 없을 때의 초기 가중치 (합 100)"
  type        = map(number)
  default = {
    aws = 100
    gcp = 0
  }

  validation {
    condition     = sum(values(var.entrypoint_default_weights)) == 100
    error_message = "가중치 합은 100 이어야 한다."
  }
}

variable "entrypoint_secondary_zones" {
  description = "진입점 보조 VM 을 둘 존 접미사 목록 (예 [\"b\"] → asia-northeast3-b 에 echo-dev-entry-b). 비어 있으면 주 VM 한 대만 (인프라 5.1 PoC)"
  type        = list(string)
  default     = []
}

variable "entrypoint_admin_cidrs" {
  description = "가중치 API(8080)·Prometheus(9090)·Grafana(3000)에 붙을 수 있는 CIDR. 비어 있으면 열지 않는다"
  type        = list(string)
  default     = []
}

# 관제탑 (echo-was)

variable "control_plane_domain" {
  description = "GCP GKE 에 올릴 echo-was API 공개 도메인"
  type        = string
  default     = "api.echoport.uk"

  validation {
    condition     = can(regex("^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)+$", var.control_plane_domain))
    error_message = "control_plane_domain 은 소문자 DNS 이름이어야 한다."
  }
}
