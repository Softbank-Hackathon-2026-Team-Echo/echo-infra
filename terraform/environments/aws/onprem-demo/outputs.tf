output "instance_id" {
  description = "온프레 시연 기기 EC2 ID (onprem/hosts/ec2-ssm.sh 인자)"
  value       = aws_instance.host.id
}

output "public_ip" {
  description = "온프레 시연 기기의 고정 공인 IP(EIP). 진입점 9090 방화벽(GCP dev 루트 entrypoint_remote_write_cidrs)의 원본"
  value       = aws_eip.host.public_ip
}

output "region" {
  description = "기기 리전"
  value       = var.region
}

output "tunnel_credentials_parameter" {
  description = "터널 자격 증명 JSON 을 넣을 SSM SecureString 이름 (값은 Terraform 밖에서 넣는다)"
  value       = "${var.ssm_parameter_prefix}/cf-tunnel-credentials"
}
