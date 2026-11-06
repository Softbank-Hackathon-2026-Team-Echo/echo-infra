# AI 검증용 테스트 DB (echo-ai-agent #22 · 11/6 "샌드박스에서 점검·코드 변경" 변경안의 "전용 테스트 DB").
# 운영 DB(EKS A·GKE B)와 별개인 Cloud SQL. 샌드박스 VPC 의 사설 IP 로만 닿는다(공인 IP 없음, 운영 VPC 와 연결 없음).
# echo-demo-app·echo-demo-db 시험은 표를 비우고 다시 만들므로, 수정안 검증은 이 DB 에서만 한다.
# 비밀번호는 apply 때만 만들어(ephemeral) DB 사용자와 비밀에 write-only 로 넣는다 → state·저장소에 값 0건.

# Cloud SQL 사설 IP 용 예약 대역(Google 관리 VPC 와의 서비스 네트워킹 피어링). 운영 망과는 연결되지 않는다.
resource "google_compute_global_address" "testdb" {
  name          = "${local.name}-testdb-psa"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  address       = cidrhost(var.testdb_psa_cidr, 0)
  prefix_length = tonumber(split("/", var.testdb_psa_cidr)[1])
  network       = google_compute_network.this.id
}

resource "google_service_networking_connection" "testdb" {
  network                 = google_compute_network.this.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.testdb.name]

  depends_on = [google_project_service.servicenetworking]
}

# 나가는 연결: 443 외에 테스트 DB 대역의 5432 만 더 연다(egress_deny 65000 보다 먼저).
resource "google_compute_firewall" "egress_testdb" {
  name      = "${local.name}-egress-testdb"
  network   = google_compute_network.this.name
  direction = "EGRESS"
  priority  = 900

  allow {
    protocol = "tcp"
    ports    = ["5432"]
  }

  destination_ranges = [var.testdb_psa_cidr]
  target_tags        = [local.tag]
}

resource "google_sql_database_instance" "testdb" {
  name                = "${local.name}-testdb"
  database_version    = "POSTGRES_17"
  region              = var.region
  deletion_protection = false # 시험용. 지워도 되는 데이터만 둔다

  settings {
    edition           = "ENTERPRISE"
    tier              = var.testdb_tier
    availability_type = "ZONAL"
    disk_type         = "PD_SSD"
    disk_size         = 10
    activation_policy = var.vm_running ? "ALWAYS" : "NEVER" # VM 을 멈추면 DB 도 멈춘다

    ip_configuration {
      ipv4_enabled    = false
      private_network = google_compute_network.this.id
      ssl_mode        = "ENCRYPTED_ONLY"
    }

    backup_configuration {
      enabled = false
    }

    location_preference {
      zone = var.zone
    }
  }

  depends_on = [google_service_networking_connection.testdb, google_project_service.sqladmin]
}

resource "google_sql_database" "testdb" {
  name     = var.testdb_name
  instance = google_sql_database_instance.testdb.name
}

ephemeral "random_password" "testdb" {
  length  = 32
  special = false # 접속 문자열에 그대로 넣는다(URL 인코딩 없음)
}

resource "google_sql_user" "testdb" {
  name                = var.testdb_user
  instance            = google_sql_database_instance.testdb.name
  password_wo         = ephemeral.random_password.testdb.result
  password_wo_version = var.testdb_password_version
}

# 러너가 읽는 접속 문자열. 비밀번호를 바꾸려면 testdb_password_version 을 올려 apply(사용자·비밀이 함께 바뀐다).
resource "google_secret_manager_secret_version" "testdb_url" {
  secret                 = google_secret_manager_secret.runner["test-database-url"].id
  secret_data_wo         = "postgresql://${var.testdb_user}:${ephemeral.random_password.testdb.result}@${google_sql_database_instance.testdb.private_ip_address}:5432/${var.testdb_name}?sslmode=require"
  secret_data_wo_version = var.testdb_password_version

  depends_on = [google_sql_user.testdb, google_sql_database.testdb]
}
