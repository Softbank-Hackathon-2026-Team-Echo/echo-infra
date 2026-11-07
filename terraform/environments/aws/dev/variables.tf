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

variable "cutover_google_service_account_id" {
  description = "컷오버 Job GSA 의 uniqueId (GCP 루트 출력값 cutover_service_account_unique_id). 비우면 cutover 역할·access entry 를 만들지 않는다"
  type        = string
  default     = ""

  validation {
    condition     = var.cutover_google_service_account_id == "" || can(regex("^[0-9]{10,}$", var.cutover_google_service_account_id))
    error_message = "GSA 의 uniqueId(숫자)를 넣는다. 이메일이 아니다."
  }
}

variable "apps_domain" {
  description = "AWS 환경별 앱 주소의 하위 도메인 (echo-was aws 환경 config.ingressDomain). 인증서는 *.<이 값>"
  type        = string
  default     = "aws-tokyo.echoport.uk"
}

# AWS Load Balancer Controller (lbc.tf). dev 는 11/2 에 손으로 만든 이름을 그대로 쓴다(재생성 방지). 새 환경은 비워 둔다.
variable "lbc_role_name" {
  description = "ALB 컨트롤러 IAM 역할 이름. 비우면 <cluster>-lbc"
  type        = string
  default     = ""
}

variable "lbc_policy_name" {
  description = "ALB 컨트롤러 IAM 정책 이름. 비우면 <cluster>-lbc-policy"
  type        = string
  default     = ""
}

# 진입점 c (인프라 17, entrypoint-c.tf). AWS 서울에 GCP 진입점 a·b 와 같은 Envoy 한 벌을 하나 더 둔다.
# Cloudflare Load Balancer 가 GCP NLB(a·b) → AWS VM c 순서로 페일오버한다. 기본 꺼짐 = 지금과 같다(자원 0개).

variable "entrypoint_c_enabled" {
  description = "AWS 서울 진입점 VM c 와 그 부속(보안 그룹·IAM·EIP·설정 버킷)을 만든다 (인프라 17). false 면 아무것도 만들지 않는다"
  type        = bool
  default     = false
}

variable "entrypoint_c_region" {
  description = "진입점 c 리전. 서울(GCP a·b 와 같은 도시, 다른 회사). 도쿄(ap-northeast-1)는 재난 시나리오 리전이라 쓰지 않는다"
  type        = string
  default     = "ap-northeast-2"

  validation {
    condition     = var.entrypoint_c_region != "ap-northeast-1"
    error_message = "도쿄는 재난(대피 출발) 리전이라 입구를 두지 않는다."
  }
}

variable "entrypoint_c_az_suffix" {
  description = "기본 VPC 의 어느 AZ 기본 서브넷에 둘지 (a·b·c·d). 온프레 시연 기기(onprem-demo)와 같은 서울 기본 VPC"
  type        = string
  default     = "a"
}

variable "entrypoint_c_instance_type" {
  description = "진입점 c 크기. GCP a·b 는 e2-small(2GB). 프리 플랜 계정은 t3.small 같은 허용 기종만 뜬다"
  type        = string
  default     = "t3.small"
}

variable "entrypoint_c_upstreams" {
  description = "진입점 c 의 환경별 업스트림 host:port. aws = 닻 ALB DNS:80 (GCP 쪽과 같은 값), gcp = ingress-nginx **외부** LB IP:80 (c 의 EIP 만 허용, cluster-addons/gke/ingress-nginx-external-entry-c.yaml). 내부 LB 10.60.0.8 은 AWS 에서 닿지 않는다"
  type        = map(string)
  default = {
    aws = "placeholder.invalid:80"
    gcp = "placeholder.invalid:80"
  }
}

variable "entrypoint_c_default_weights" {
  description = "진입점 c 가 처음 뜰 때(동기화 전) 가중치. 곧 a 의 /weights 로 덮인다. 합 100"
  type        = map(number)
  default = {
    aws = 100
    gcp = 0
  }

  validation {
    condition     = sum(values(var.entrypoint_c_default_weights)) == 100
    error_message = "가중치 합은 100 이어야 한다."
  }
}

variable "entrypoint_c_sync_from" {
  description = "가중치를 당겨 올 주 진입점 a 의 가중치 API (예 http://<GCP 출력 entrypoint_ip>:8080). 2초마다 GET /weights. 비우면 동기화하지 않는다(기본 가중치로만 흐른다). GCP 쪽 entrypoint_weights_sync_cidrs 에 c 의 EIP 가 있어야 닿는다"
  type        = string
  default     = ""

  validation {
    condition     = var.entrypoint_c_sync_from == "" || can(regex("^http://[^/]+:[0-9]+$", var.entrypoint_c_sync_from))
    error_message = "http://<호스트>:<포트> 꼴(끝 슬래시 없이)이어야 한다."
  }
}

variable "entrypoint_c_token_parameter" {
  description = "진입점 a·b 와 같은 가중치 API 토큰을 담은 SSM SecureString 이름. Terraform 은 값을 만들지 않는다(state 에 비밀값 0) — 적용 절차가 GCP Secret Manager 값을 파이프로 넣는다"
  type        = string
  default     = "/echo/dev/entry-c/weights-token"
}

variable "entrypoint_c_ingress_cidrs" {
  description = "진입점 c 의 80·443 을 열어 줄 CIDR. 기본값은 Cloudflare IPv4 대역(https://www.cloudflare.com/ips-v4, 2026-11-07 15개) — 손님과 Cloudflare LB 헬스체크가 모두 이 대역에서 온다"
  type        = list(string)
  default = [
    "173.245.48.0/20",
    "103.21.244.0/22",
    "103.22.200.0/22",
    "103.31.4.0/22",
    "141.101.64.0/18",
    "108.162.192.0/18",
    "190.93.240.0/20",
    "188.114.96.0/20",
    "197.234.240.0/22",
    "198.41.128.0/17",
    "162.158.0.0/15",
    "104.16.0.0/13",
    "104.24.0.0/14",
    "172.64.0.0/13",
    "131.0.72.0/22",
  ]

  validation {
    condition     = length(var.entrypoint_c_ingress_cidrs) > 0 && alltrue([for c in var.entrypoint_c_ingress_cidrs : can(cidrhost(c, 0)) && c != "0.0.0.0/0"])
    error_message = "CIDR 형식이어야 하고 0.0.0.0/0 은 안 된다(Cloudflare 를 거치지 않는 직접 접근을 막는다)."
  }
}
