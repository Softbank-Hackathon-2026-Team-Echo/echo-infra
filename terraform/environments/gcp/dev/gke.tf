# GKE 존 클러스터 하나 (Standard). 대피처 1: 평소 Warm(노드 2대), 경계 시 Hot(3대).
# 노드는 전용 서비스 계정으로 돌고, 파드 권한은 Workload Identity 로 준다(노드 키 없음).
resource "google_service_account" "nodes" {
  account_id   = "${local.cluster_name}-node"
  display_name = "GKE 노드 (${local.cluster_name})"

  depends_on = [
    google_project_service.this["iam.googleapis.com"],
    google_project_service.this["cloudresourcemanager.googleapis.com"],
  ]
}

resource "google_project_iam_member" "nodes" {
  for_each = toset([
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
    "roles/monitoring.viewer",
    "roles/stackdriver.resourceMetadata.writer",
    "roles/artifactregistry.reader",
  ])
  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.nodes.email}"

  # 첫 apply 때 API 가 켜지기 전에 IAM 을 만들지 않게 한다
  depends_on = [google_project_service.this["cloudresourcemanager.googleapis.com"]]
}

resource "google_container_cluster" "this" {
  name     = local.cluster_name
  location = var.zone

  network    = google_compute_network.this.id
  subnetwork = google_compute_subnetwork.this.id

  # 기본 노드 풀은 지우고 아래 node pool 로 관리한다.
  remove_default_node_pool = true
  initial_node_count       = 1

  networking_mode   = "VPC_NATIVE"
  datapath_provider = "ADVANCED_DATAPATH" # Dataplane V2: NetworkPolicy 기본 지원 (샌드박스 네임스페이스 격리용)

  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }

  release_channel {
    channel = var.gke_release_channel
  }

  # 노드는 사설 IP, API 엔드포인트는 공개 + 허용 CIDR (AWS EKS 와 같은 모양)
  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false
    master_ipv4_cidr_block  = var.master_cidr
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

  addons_config {
    http_load_balancing {
      disabled = false
    }
    horizontal_pod_autoscaling {
      disabled = false
    }
    gce_persistent_disk_csi_driver_config {
      enabled = true
    }
  }

  # echo-was 는 값 자체를 Terraform state 에 두지 않는다. Secret Manager CSI 와
  # SecretSync CRD 로 Secret Manager 값을 파드의 파일·Kubernetes Secret 으로 전달한다.
  secret_manager_config {
    enabled = true

    rotation_config {
      enabled           = true
      rotation_interval = "120s"
    }
  }

  secret_sync_config {
    enabled = true

    rotation_config {
      enabled           = true
      rotation_interval = "120s"
    }
  }

  # make down 으로 지울 수 있어야 한다 (NFR-16, 해커톤 dev)
  deletion_protection = false

  depends_on = [
    google_project_service.this["container.googleapis.com"],
    google_project_iam_member.nodes,
  ]
}

resource "google_container_node_pool" "default" {
  name     = "default"
  cluster  = google_container_cluster.this.name
  location = var.zone

  initial_node_count = var.node_min_count

  autoscaling {
    min_node_count = var.node_min_count
    max_node_count = var.node_max_count
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  node_config {
    machine_type    = var.node_machine_type
    disk_size_gb    = var.node_disk_size_gb
    disk_type       = "pd-balanced"
    service_account = google_service_account.nodes.email
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
      project = var.project
      env     = var.environment
    }
  }

  lifecycle {
    ignore_changes = [initial_node_count]
  }
}

# 팀원 클러스터 관리자 권한. kubeconfig 는 `gcloud container clusters get-credentials` 로 받는다.
resource "google_project_iam_member" "gke_admin" {
  for_each = toset(var.gke_admin_members)
  project  = var.project_id
  role     = "roles/container.admin"
  member   = each.value

  depends_on = [google_project_service.this["cloudresourcemanager.googleapis.com"]]
}
