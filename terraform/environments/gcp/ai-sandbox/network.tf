# AI 에이전트 샌드박스 망 (echo-ai-agent specs/ai-1-sdk-model-sandbox.md 4·7절).
# 운영 VPC(echo-dev)와 피어링·공유 VPC·VPN 이 없다. 들어오는 연결은 IAP SSH 만, 나가는 연결은 NAT 로 443 만.
locals {
  name = "${var.project}-${var.environment}"
  tag  = "ai-sandbox"
}

resource "google_compute_network" "this" {
  name                    = local.name
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"
}

resource "google_compute_subnetwork" "this" {
  name                     = "${local.name}-${var.region}"
  network                  = google_compute_network.this.id
  region                   = var.region
  ip_cidr_range            = var.subnet_cidr
  private_ip_google_access = true
}

resource "google_compute_router" "this" {
  name    = local.name
  network = google_compute_network.this.id
  region  = var.region
}

# VM 에 공인 IP 가 없어 나가는 연결은 이 NAT 로만 나간다(주소는 자동 할당).
resource "google_compute_router_nat" "this" {
  name                               = local.name
  router                             = google_compute_router.this.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

# 들어오는 연결: VPC 기본값이 모두 거부다. 관리는 IAP 터널 대역에서 22 만(OS Login).
resource "google_compute_firewall" "iap_ssh" {
  name      = "${local.name}-iap-ssh"
  network   = google_compute_network.this.name
  direction = "INGRESS"

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["35.235.240.0/20"]
  target_tags   = [local.tag]
}

# 나가는 연결: 443 만 연다(Anthropic API·api.echoport.uk·GitHub·패키지 저장소).
# 접속할 도메인 목록은 VM 의 제어 프로세스가 지키고, 작업 공간 컨테이너는 네트워크가 없다.
# 메타데이터 서버(169.254.169.254)·내부 DNS 는 방화벽 대상이 아니라 그대로 닿는다.
resource "google_compute_firewall" "egress_https" {
  name      = "${local.name}-egress-https"
  network   = google_compute_network.this.name
  direction = "EGRESS"
  priority  = 1000

  allow {
    protocol = "tcp"
    ports    = ["443"]
  }

  destination_ranges = ["0.0.0.0/0"]
}

resource "google_compute_firewall" "egress_deny" {
  name      = "${local.name}-egress-deny"
  network   = google_compute_network.this.name
  direction = "EGRESS"
  priority  = 65000

  deny {
    protocol = "all"
  }

  destination_ranges = ["0.0.0.0/0"]
}
