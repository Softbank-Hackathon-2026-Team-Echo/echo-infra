output "state_bucket" {
  description = "다른 루트의 backend.hcl 에 넣을 state 버킷 이름"
  value       = aws_s3_bucket.state.bucket
}

output "region" {
  value = var.region
}
