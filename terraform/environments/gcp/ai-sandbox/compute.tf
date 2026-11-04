# 샌드박스 VM 1대. 실행마다 새 Docker 컨테이너(작업 공간·검사)를 만들고 지운다(echo-ai-agent 러너).
# 공인 IP 없음, Shielded VM, OS Login. 러너 코드·키는 여기서 싣지 않는다(시작 스크립트는 Docker 설치만).
resource "google_compute_instance" "runner" {
  name         = "${local.name}-runner"
  machine_type = var.machine_type
  zone         = var.zone
  tags         = [local.tag]

  desired_status            = var.vm_running ? "RUNNING" : "TERMINATED"
  allow_stopping_for_update = true

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-12"
      size  = var.boot_disk_gb
      type  = "pd-balanced"
    }
  }

  # access_config 를 두지 않는다 = 공인 IP 없음.
  network_interface {
    subnetwork = google_compute_subnetwork.this.id
  }

  service_account {
    email  = google_service_account.runner.email
    scopes = ["cloud-platform"]
  }

  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  metadata = {
    enable-oslogin         = "TRUE"
    block-project-ssh-keys = "TRUE"
    startup-script         = file("${path.module}/startup.sh")
  }

  depends_on = [google_compute_router_nat.this]
}
