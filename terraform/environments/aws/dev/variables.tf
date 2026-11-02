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
  description = "VPC CIDR. GCP 서울·온프레 K3s 대역과 겹치면 안 된다 (첫 apply 전 확정)"
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
