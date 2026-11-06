output "network_name" {
  description = "샌드박스 VPC (운영 echo-dev 와 연결 없음)"
  value       = google_compute_network.this.name
}

output "subnet_cidr" {
  description = "샌드박스 서브넷 대역"
  value       = google_compute_subnetwork.this.ip_cidr_range
}

output "runner_vm_name" {
  description = "샌드박스 VM 이름. 접속: gcloud compute ssh <이름> --zone <zone> --tunnel-through-iap"
  value       = google_compute_instance.runner.name
}

output "runner_vm_zone" {
  description = "샌드박스 VM 존"
  value       = google_compute_instance.runner.zone
}

output "runner_service_account" {
  description = "샌드박스 VM 서비스 계정(프로젝트 역할 0개, 아래 비밀 읽기만)"
  value       = google_service_account.runner.email
}

output "runner_secret_ids" {
  description = "러너가 읽는 비밀(값은 사람이 넣는다): 이름 → secret_id"
  value       = { for name, secret in google_secret_manager_secret.runner : name => secret.secret_id }
}

output "testdb_instance" {
  description = "AI 검증용 테스트 DB(Cloud SQL, 운영 DB 와 별개)"
  value       = google_sql_database_instance.testdb.name
}

output "testdb_private_ip" {
  description = "테스트 DB 사설 IP(샌드박스 VPC 에서만 닿는다). 접속 문자열은 비밀 test-database-url"
  value       = google_sql_database_instance.testdb.private_ip_address
}
