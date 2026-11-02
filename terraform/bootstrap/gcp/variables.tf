variable "project_id" {
  description = "본선 GCP 프로젝트 ID (콘솔에서 만든 뒤 결제 계정을 붙인다)"
  type        = string
}

variable "project" {
  description = "리소스 이름 접두어와 project 라벨 값"
  type        = string
  default     = "echo"
}

variable "region" {
  description = "state 버킷 리전. 11/1 회의: 대피처는 GCP 서울"
  type        = string
  default     = "asia-northeast3"
}
