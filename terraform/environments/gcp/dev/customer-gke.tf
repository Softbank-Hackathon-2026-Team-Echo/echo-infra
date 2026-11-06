# 고객 워크로드 전용 GKE 존 클러스터 (인프라 16, specs/infra-16-customer-cluster-split.md).
# 관제탑(echo-was)이 있는 echo-dev-gke 에서 gcp-seoul 고객 환경(고객 앱 네임스페이스·ingress-nginx·Postgres B)을 떼어 낸다.
# - 같은 프로젝트·같은 VPC, 새 서브넷(노드·파드·서비스 대역 모두 새로). 기존 서브넷·클러스터·방화벽은 바꾸지 않는다.
# - 밖으로 나가는 주소는 기존 Cloud NAT(ALL_SUBNETWORKS) 그대로 → AWS 쪽 허용 목록(NAT 34.64.x)은 바꿀 필요 없다.
# - VPC 안 허용 규칙(network.tf internal)은 관제탑 대역만 출발지로 둔다. 그래서 고객 클러스터 → 관제탑 노드·파드는
#   기본 거부이고, 관제탑·진입점 → 고객 클러스터(내부 LB·헬스체크)는 지금 규칙으로 열린다. 고객 쪽에서 나가야 하는
#   것은 OTel 수집기 → 진입점 Prometheus(9090) 하나라 아래에 그 규칙만 더한다.
# - 노드는 따로 만든 서비스 계정으로 돈다(관제탑 노드 SA 와 분리). 파드 권한은 Workload Identity.
# - var.customer_gke_enabled = false 면 이 파일의 자원을 하나도 만들지 않는다(적용 시점은 팀 합의 뒤).
locals {
  customer_cluster_name = "${local.name}-customer-gke"
  customer_enabled      = var.customer_gke_enabled ? 1 : 0
}

resource "google_compute_subnetwork" "customer" {
  count = local.customer_enabled

  name                     = "${local.name}-customer-${var.region}"
  network                  = google_compute_network.this.id
  region                   = var.region
  ip_cidr_range            = var.customer_subnet_cidr
  private_ip_google_access = true

  secondary_ip_range {
    range_name    = "customer-pods"
    ip_cidr_range = var.customer_pods_cidr
  }

  secondary_ip_range {
    range_name    = "customer-services"
    ip_cidr_range = var.customer_services_cidr
  }
}

resource "google_service_account" "customer_nodes" {
  count = local.customer_enabled

  account_id   = "${local.customer_cluster_name}-node"
  display_name = "GKE 노드 (${local.customer_cluster_name})"

  depends_on = [
    google_project_service.this["iam.googleapis.com"],
    google_project_service.this["cloudresourcemanager.googleapis.com"],
  ]
}

# 관제탑 노드 SA 와 같은 최소 역할(로그·지표 쓰기, 이미지 읽기).
resource "google_project_iam_member" "customer_nodes" {
  for_each = var.customer_gke_enabled ? toset([
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
    "roles/monitoring.viewer",
    "roles/stackdriver.resourceMetadata.writer",
    "roles/artifactregistry.reader",
  ]) : toset([])
  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.customer_nodes[0].email}"

  depends_on = [google_project_service.this["cloudresourcemanager.googleapis.com"]]
}

resource "google_container_cluster" "customer" {
  count = local.customer_enabled

  name     = local.customer_cluster_name
  location = var.zone

  network    = google_compute_network.this.id
  subnetwork = google_compute_subnetwork.customer[0].id

  remove_default_node_pool = true
  initial_node_count       = 1

  # 임시 기본 풀(만들자마자 지워지는 1대)의 모양. 지정하지 않으면 GKE 기본값(e2-medium, pd-balanced 100GB)이라
  # 서울 SSD_TOTAL_GB 할당량(250)을 넘겨 클러스터 생성이 실패한다(11/7 첫 적용). pd-standard 는 SSD 할당량을 쓰지 않는다.
  # 고객 노드 모양은 아래 google_container_node_pool.customer 가 정한다.
  node_config {
    machine_type    = "e2-small"
    disk_size_gb    = 20
    disk_type       = "pd-standard"
    service_account = google_service_account.customer_nodes[0].email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]
  }

  networking_mode   = "VPC_NATIVE"
  datapath_provider = "ADVANCED_DATAPATH" # Dataplane V2: 고객 네임스페이스 NetworkPolicy

  ip_allocation_policy {
    cluster_secondary_range_name  = "customer-pods"
    services_secondary_range_name = "customer-services"
  }

  release_channel {
    channel = var.gke_release_channel
  }

  # 관제탑과 같은 패치 수준(CVE-2026-98432 수정) 이상으로 시작한다.
  min_master_version = var.customer_gke_min_master_version

  # 자동 업그레이드 교란 최소: 정비 창은 한국 시간 새벽(03:00~07:00 KST = 18:00~22:00 UTC)만,
  # 그리고 시연이 끝날 때까지 업그레이드 제외(관제탑 클러스터의 demo-freeze 와 같은 끝 시각).
  maintenance_policy {
    recurring_window {
      start_time = "2026-11-01T18:00:00Z"
      end_time   = "2026-11-01T22:00:00Z"
      recurrence = "FREQ=DAILY"
    }

    dynamic "maintenance_exclusion" {
      for_each = var.customer_gke_freeze_end_time == "" ? [] : [var.customer_gke_freeze_end_time]
      content {
        exclusion_name = "demo-freeze"
        start_time     = var.customer_gke_freeze_start_time
        end_time       = maintenance_exclusion.value
        exclusion_options {
          scope = "NO_UPGRADES"
        }
      }
    }
  }

  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false
    master_ipv4_cidr_block  = var.customer_master_cidr
  }

  master_authorized_networks_config {
    dynamic "cidr_blocks" {
      for_each = var.gke_public_access_cidrs
      content {
        cidr_block   = cidr_blocks.value
        display_name = "allowed-${cidr_blocks.key}"
      }
    }
  }

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  # 고객 앱 비밀은 echo-was 가 Secret Manager 에서 읽어 네임스페이스 Secret 으로 넣는다(API 서버 10).
  # 이 클러스터 파드가 Secret Manager 를 직접 읽지 않으므로 Secret Manager CSI·SecretSync 는 켜지 않는다.

  deletion_protection = false

  # 기본 풀은 생성 직후 지워지므로, 그 뒤 GKE 가 돌려주는 node_config 차이로 클러스터를 교체하지 않게 한다.
  lifecycle {
    ignore_changes = [node_config]
  }

  depends_on = [
    google_project_service.this["container.googleapis.com"],
    google_project_iam_member.customer_nodes,
  ]
}

resource "google_container_node_pool" "customer" {
  count = local.customer_enabled

  name     = "customer"
  cluster  = google_container_cluster.customer[0].name
  location = var.zone

  initial_node_count = var.customer_node_min_count

  autoscaling {
    min_node_count = var.customer_node_min_count
    max_node_count = var.customer_node_max_count
  }

  # 릴리스 채널 클러스터는 자동 업그레이드를 끌 수 없다. 대신 위 정비 창·제외 기간으로 시점을 묶고,
  # 노드 교체 때 한 대씩만 바꾼다(빈 자리 1 = 잠깐 1대 더, 비용 몇 분어치).
  management {
    auto_repair  = true
    auto_upgrade = true
  }

  upgrade_settings {
    max_surge       = 1
    max_unavailable = 0
  }

  node_config {
    machine_type    = var.customer_node_machine_type
    disk_size_gb    = var.customer_node_disk_size_gb
    disk_type       = "pd-balanced"
    service_account = google_service_account.customer_nodes[0].email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]

    metadata = {
      disable-legacy-endpoints = "true"
    }

    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }

    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    labels = {
      project  = var.project
      env      = var.environment
      workload = "customer"
    }
  }

  lifecycle {
    ignore_changes = [initial_node_count]
  }
}

# 고객 클러스터 OTel 수집기 → 진입점 Prometheus remote write(9090). 고객 대역에서 나가는 유일한 VPC 안 통신이다.
resource "google_compute_firewall" "customer_to_entry_metrics" {
  count = local.customer_enabled

  name    = "${local.name}-customer-to-entry-metrics"
  network = google_compute_network.this.name

  allow {
    protocol = "tcp"
    ports    = ["9090"]
  }

  source_ranges = [var.customer_subnet_cidr, var.customer_pods_cidr]
  target_tags   = ["entrypoint"]
}
