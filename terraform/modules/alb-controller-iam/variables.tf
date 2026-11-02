variable "cluster_name" {
  description = "컨트롤러가 돌아가는 EKS 클러스터 이름 (예: echo-dev-eks)"
  type        = string
}

variable "role_name" {
  description = "컨트롤러가 쓰는 IAM 역할 이름"
  type        = string
}

variable "policy_name" {
  description = "컨트롤러 권한 정책 이름"
  type        = string
}

variable "namespace" {
  description = "컨트롤러 ServiceAccount 가 있는 네임스페이스"
  type        = string
  default     = "kube-system"
}

variable "service_account" {
  description = "컨트롤러 ServiceAccount 이름 (Helm 차트 기본값)"
  type        = string
  default     = "aws-load-balancer-controller"
}
