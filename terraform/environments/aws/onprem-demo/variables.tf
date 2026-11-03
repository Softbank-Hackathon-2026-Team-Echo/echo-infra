variable "project" {
  description = "리소스 이름 접두어"
  type        = string
  default     = "echo"
}

variable "environment" {
  description = "환경 이름(태그·이름). 시연에서 온프레로 간주하는 기기 한 대"
  type        = string
  default     = "onprem-demo"
}

variable "region" {
  description = "기기를 둘 리전. 출발 환경(AWS 도쿄)과 다른 곳에 둔다"
  type        = string
  default     = "ap-northeast-2"
}

variable "availability_zone_suffix" {
  description = "기본 VPC 의 어느 AZ 기본 서브넷에 둘지 (a·b·c·d)"
  type        = string
  default     = "a"
}

variable "instance_type" {
  description = "기기 크기. 프리 플랜 계정은 t3.small·c7i-flex.large 같은 허용 기종만 띄울 수 있다"
  type        = string
  default     = "t3.small"
}

variable "root_volume_gb" {
  description = "루트 디스크(gp3) 크기. k3s 이미지·PostgreSQL 데이터가 여기에 쌓인다"
  type        = number
  default     = 20
}

variable "ssm_parameter_prefix" {
  description = "기기가 읽을 수 있는 SSM 파라미터 경로(터널 자격 증명). 값은 Terraform 밖에서 넣는다"
  type        = string
  default     = "/echo/onprem-demo"
}
