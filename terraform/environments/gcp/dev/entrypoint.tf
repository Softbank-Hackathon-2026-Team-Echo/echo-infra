# 고정 진입점(Envoy) VM. 고객 앱 주소 {서비스}.echoport.uk 가 여기로 오고, 가중치·헬스체크로 AWS·GCP 에 나눈다.
# 재난 리전(AWS 도쿄) 밖, 그리고 GKE 와도 분리해 둔다(대피처 클러스터를 늘리고 줄여도 진입점은 그대로).
# 설정 파일은 entrypoint/ 디렉터리가 단일 출처이고, 이 파일은 그걸 VM 메타데이터로 실어 /opt/entrypoint 에 쓴다.
locals {
  entry_name = "${local.name}-entry"

  # VM 에 쓰는 파일 (경로 → 내용). 허용 목록 패턴이라 .env·README 는 실리지 않는다. 비밀값은 없다(토큰·비밀번호는 VM 이 첫 부팅 때 만든다).
  entry_src = "${path.module}/../../../../entrypoint"
  entry_files = {
    for p in setunion(
      fileset(local.entry_src, "docker-compose.yml"),
      fileset(local.entry_src, "weights-api/*"),
      fileset(local.entry_src, "config/**"),
      fileset(local.entry_src, "scripts/render-prometheus-web.sh"),
    ) : p => file("${local.entry_src}/${p}")
  }

  entry_upstreams       = join(",", [for env, hp in var.entrypoint_upstreams : "${env}=${hp}"])
  entry_default_weights = join(",", [for env, w in var.entrypoint_default_weights : "${env}=${w}"])
}

resource "google_compute_address" "entry" {
  name   = local.entry_name
  region = var.region

  depends_on = [google_project_service.this["compute.googleapis.com"]]
}

resource "google_compute_firewall" "entry_public" {
  name    = "${local.entry_name}-public"
  network = google_compute_network.this.name

  allow {
    protocol = "tcp"
    ports    = ["80", "443"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["entrypoint"]
}

# 가중치 API·Prometheus·Grafana 는 허용 CIDR 에서만. 비어 있으면 열지 않는다 (SSH 터널로 본다).
resource "google_compute_firewall" "entry_admin" {
  count = length(var.entrypoint_admin_cidrs) > 0 ? 1 : 0

  name    = "${local.entry_name}-admin"
  network = google_compute_network.this.name

  allow {
    protocol = "tcp"
    ports    = ["8080", "9090", "3000"]
  }

  source_ranges = var.entrypoint_admin_cidrs
  target_tags   = ["entrypoint"]
}

# 인프라 9: 클러스터 OTel 수집기가 Prometheus(9090) /api/v1/write 로 보낸다. admin CIDR(EKS·GKE NAT)에 없는 곳
# (온프레 EC2 공인 IP)만 9090 하나를 연다. 인증은 Prometheus basic auth(web.yml, entrypoint_prometheus_remote_write).
resource "google_compute_firewall" "entry_remote_write" {
  count = length(var.entrypoint_remote_write_cidrs) > 0 ? 1 : 0

  name    = "${local.entry_name}-remote-write"
  network = google_compute_network.this.name

  allow {
    protocol = "tcp"
    ports    = ["9090"]
  }

  source_ranges = var.entrypoint_remote_write_cidrs
  target_tags   = ["entrypoint"]
}

# SSH 는 IAP 터널로만 (OS Login). 공개 22 는 열지 않는다.
resource "google_compute_firewall" "entry_iap_ssh" {
  name    = "${local.entry_name}-iap-ssh"
  network = google_compute_network.this.name

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["35.235.240.0/20"]
  target_tags   = ["entrypoint"]
}

resource "google_service_account" "entry" {
  account_id   = local.entry_name
  display_name = "고정 진입점 VM (${local.entry_name})"

  depends_on = [
    google_project_service.this["iam.googleapis.com"],
    google_project_service.this["cloudresourcemanager.googleapis.com"],
  ]
}

resource "google_project_iam_member" "entry" {
  for_each = toset([
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
  ])
  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.entry.email}"

  depends_on = [google_project_service.this["cloudresourcemanager.googleapis.com"]]
}

# 비밀값 껍데기. 값(version)은 VM 이 첫 부팅 때 만들어 넣는다 → state 에 비밀값이 남지 않는다.
# 읽기: gcloud secrets versions access latest --secret=<이름>
resource "google_secret_manager_secret" "entry" {
  # prometheus-remote-write: 인프라 9 basic auth 비밀번호(사용자 echo-otel). VM 이 처음 켤 때 만든다.
  for_each  = toset(["weights-token", "grafana-admin", "prometheus-remote-write"])
  secret_id = "${local.entry_name}-${each.value}"

  replication {
    auto {}
  }

  depends_on = [google_project_service.this["secretmanager.googleapis.com"]]
}

resource "google_secret_manager_secret_iam_member" "entry_adder" {
  for_each  = google_secret_manager_secret.entry
  secret_id = each.value.id
  role      = "roles/secretmanager.secretVersionAdder"
  member    = "serviceAccount:${google_service_account.entry.email}"
}

resource "google_compute_instance" "entry" {
  name         = local.entry_name
  machine_type = var.entrypoint_machine_type
  zone         = var.zone
  tags         = ["entrypoint"]

  allow_stopping_for_update = true

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-12"
      size  = 20
      type  = "pd-balanced"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.this.id
    access_config {
      nat_ip = google_compute_address.entry.address
    }
  }

  service_account {
    email  = google_service_account.entry.email
    scopes = ["cloud-platform"]
  }

  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  # startup-script 는 metadata 맵에 둔다. metadata_startup_script 인자는 바뀔 때마다 VM 을 새로 만들지만
  # 맵 항목은 제자리에서 갱신된다. 부팅 때마다 돈다(멱등): 파일을 다시 쓰고 docker compose up -d --build.
  # 바꾼 뒤 다시 돌리기: sudo google_metadata_script_runner startup
  metadata = {
    enable-oslogin = "TRUE"
    startup-script = templatefile("${path.module}/entrypoint-startup.sh.tftpl", {
      files           = local.entry_files
      upstreams       = local.entry_upstreams
      default_weights = local.entry_default_weights
      project_id      = var.project_id
      secret_token    = google_secret_manager_secret.entry["weights-token"].secret_id
      secret_grafana  = google_secret_manager_secret.entry["grafana-admin"].secret_id
      secret_prom_rw  = google_secret_manager_secret.entry["prometheus-remote-write"].secret_id
      prom_rw_enabled = var.entrypoint_prometheus_remote_write
      sync_from       = "" # 주 진입점: 동기화 없음
    })
  }

  depends_on = [
    google_project_iam_member.entry,
    google_secret_manager_secret_iam_member.entry_adder,
    google_secret_manager_secret_iam_member.entry_accessor,
  ]
}

# 두 VM 이 같은 토큰·비밀번호를 쓰도록 Secret Manager 의 기존 값을 읽는다(시작 스크립트 read_secret_latest).
resource "google_secret_manager_secret_iam_member" "entry_accessor" {
  for_each  = google_secret_manager_secret.entry
  secret_id = each.value.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.entry.email}"
}

# 진입점 두 곳 (인프라 5.1 단일 장애점 PoC). 다른 존에 같은 VM 을 하나 더 두고, Cloudflare 의 *.echoport.uk 에
# 프록시된 A 레코드를 두 IP 로 둔다 — Cloudflare 는 한 IP 가 실패하면 같은 호스트의 다른 IP 로 재시도한다(LB 애드온 없이).
# 가중치는 보조가 주의 /weights 를 2초마다 당겨 맞춘다(SYNC_FROM). echo-was 는 주 진입점만 부른다(주가 죽으면 비율 변경은 못 하고 마지막 값으로 흐른다).
# 방화벽은 태그 entrypoint 로 같이 걸리고, 서비스 계정·비밀도 같이 쓴다. var.entrypoint_secondary_zones 가 비어 있으면 아무것도 만들지 않는다.
resource "google_compute_address" "entry_secondary" {
  for_each = toset(var.entrypoint_secondary_zones)
  name     = "${local.entry_name}-${each.key}"
  region   = var.region

  depends_on = [google_project_service.this["compute.googleapis.com"]]
}

resource "google_compute_instance" "entry_secondary" {
  for_each     = toset(var.entrypoint_secondary_zones)
  name         = "${local.entry_name}-${each.key}"
  machine_type = var.entrypoint_machine_type
  zone         = "${var.region}-${each.key}"
  tags         = ["entrypoint"]

  allow_stopping_for_update = true

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-12"
      size  = 20
      type  = "pd-balanced"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.this.id
    access_config {
      nat_ip = google_compute_address.entry_secondary[each.key].address
    }
  }

  service_account {
    email  = google_service_account.entry.email
    scopes = ["cloud-platform"]
  }

  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  metadata = {
    enable-oslogin = "TRUE"
    startup-script = templatefile("${path.module}/entrypoint-startup.sh.tftpl", {
      files           = local.entry_files
      upstreams       = local.entry_upstreams
      default_weights = local.entry_default_weights
      project_id      = var.project_id
      secret_token    = google_secret_manager_secret.entry["weights-token"].secret_id
      secret_grafana  = google_secret_manager_secret.entry["grafana-admin"].secret_id
      secret_prom_rw  = google_secret_manager_secret.entry["prometheus-remote-write"].secret_id
      prom_rw_enabled = var.entrypoint_prometheus_remote_write
      sync_from       = "http://${google_compute_instance.entry.network_interface[0].network_ip}:8080"
    })
  }

  depends_on = [
    google_project_iam_member.entry,
    google_secret_manager_secret_iam_member.entry_adder,
    google_secret_manager_secret_iam_member.entry_accessor,
  ]
}
