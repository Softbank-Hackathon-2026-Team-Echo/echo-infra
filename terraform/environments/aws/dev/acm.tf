# AWS 환경별 앱 주소(*.aws-tokyo.echoport.uk)의 ALB HTTPS 인증서 (API 서버 3-2 §5.1 certificateArn, §7 P3).
# DNS 는 Cloudflare 라 검증 CNAME 은 출력값(acm_validation_records)을 DNS 담당이 손으로 넣는다. 넣기 전까지 PENDING_VALIDATION.
resource "aws_acm_certificate" "apps" {
  domain_name       = "*.${var.apps_domain}"
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

output "acm_apps_certificate_arn" {
  description = "echo-was aws 환경 config.certificateArn · 닻 Ingress HTTPS 리스너"
  value       = aws_acm_certificate.apps.arn
}

output "acm_validation_records" {
  description = "Cloudflare 에 넣을 검증 CNAME (DNS only)"
  value = [for o in aws_acm_certificate.apps.domain_validation_options : {
    name  = o.resource_record_name
    type  = o.resource_record_type
    value = o.resource_record_value
  }]
}
