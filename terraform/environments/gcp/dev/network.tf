# VPC 하나, 서브넷 하나(서울). 파드·서비스는 보조 대역(VPC 네이티브).
# 노드는 사설 IP 만 갖고, 밖으로 나가는 통신은 Cloud NAT 의 고정 IP 하나로 나간다.
# 그 고정 IP 를 AWS 쪽 보안 그룹(PostgreSQL 복제 허용 목록)에 적는다 → 출력값 nat_ip.
locals {
  name         = "${var.project}-${var.environment}"
  cluster_name = "${local.name}-gke"
}

resource "google_compute_network" "this" {
  name                    = local.name
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"

  depends_on = [google_project_service.this["compute.googleapis.com"]]
}

resource "google_compute_subnetwork" "this" {
  name                     = "${local.name}-${var.region}"
  network                  = google_compute_network.this.id
  region                   = var.region
  ip_cidr_range            = var.subnet_cidr
  private_ip_google_access = true

  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = var.pods_cidr
  }

  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = var.services_cidr
  }
}

resource "google_compute_address" "nat" {
  name   = "${local.name}-nat"
  region = var.region
}

resource "google_compute_router" "this" {
  name    = local.name
  network = google_compute_network.this.id
  region  = var.region
}

resource "google_compute_router_nat" "this" {
  name                               = local.name
  router                             = google_compute_router.this.name
  region                             = var.region
  nat_ip_allocate_option             = "MANUAL_ONLY"
  nat_ips                            = [google_compute_address.nat.self_link]
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

# VPC 안 통신은 전부 허용 (노드·파드·서비스 대역). 밖에서 들어오는 것은 LB·방화벽 규칙으로 따로 연다.
resource "google_compute_firewall" "internal" {
  name    = "${local.name}-internal"
  network = google_compute_network.this.name

  allow {
    protocol = "tcp"
  }
  allow {
    protocol = "udp"
  }
  allow {
    protocol = "icmp"
  }

  source_ranges = [var.subnet_cidr, var.pods_cidr, var.services_cidr]
}
