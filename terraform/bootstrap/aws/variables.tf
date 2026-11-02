variable "project" {
  description = "리소스 이름 접두어와 project 태그 값"
  type        = string
  default     = "echo"
}

variable "region" {
  description = "AWS 리전 (echo-was aws 환경 config 의 region 형식)"
  type        = string
  default     = "ap-northeast-1"
}
