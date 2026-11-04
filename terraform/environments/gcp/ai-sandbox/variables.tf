variable "project_id" {
  description = "본선 GCP 프로젝트 ID (gcp/dev 와 같은 프로젝트)"
  type        = string
}

variable "project" {
  description = "리소스 이름 접두어와 project 라벨 값"
  type        = string
  default     = "echo"
}

variable "environment" {
  description = "env 라벨과 이름에 쓰는 단계. 운영(dev)과 이름이 겹치지 않게 sandbox"
  type        = string
  default     = "sandbox"
}

variable "region" {
  description = "GCP 리전"
  type        = string
  default     = "asia-northeast3"
}

variable "zone" {
  description = "VM 을 두는 존"
  type        = string
  default     = "asia-northeast3-a"
}

variable "subnet_cidr" {
  description = "샌드박스 서브넷. 다른 망과 연결하지 않지만 대역 표(contracts/aws-outputs.md)와 겹치지 않게 둔다"
  type        = string
  default     = "10.70.0.0/24"
}

variable "machine_type" {
  description = "샌드박스 VM 크기. 실행마다 작업 공간·검사 컨테이너 하나씩(메모리 512MB 상한)"
  type        = string
  default     = "e2-standard-2"
}

variable "boot_disk_gb" {
  description = "부트 디스크(GB). 작업 공간·검사 이미지를 받아 둔다"
  type        = number
  default     = 30
}

variable "vm_running" {
  description = "false 면 VM 을 멈춘다(디스크는 남김). 쓰지 않을 때 비용을 줄인다"
  type        = bool
  default     = true
}
