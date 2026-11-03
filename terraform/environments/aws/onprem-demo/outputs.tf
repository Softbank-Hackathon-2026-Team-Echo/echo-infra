output "instance_id" {
  description = "온프레 시연 기기 EC2 ID (onprem/hosts/ec2-ssm.sh 인자)"
  value       = aws_instance.host.id
}

output "region" {
  description = "기기 리전"
  value       = var.region
}

output "tunnel_credentials_parameter" {
  description = "터널 자격 증명 JSON 을 넣을 SSM SecureString 이름 (값은 Terraform 밖에서 넣는다)"
  value       = "${var.ssm_parameter_prefix}/cf-tunnel-credentials"
}
