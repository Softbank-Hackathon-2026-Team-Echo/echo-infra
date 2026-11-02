# 월 비용 알림 (NFR-13). 실제 비용 80% 와 예측 비용 100% 에서 메일을 보낸다.
# 결제 계정 ID 가 없으면 만들지 않는다 (콘솔 예산을 쓴다). 적용하는 사람은 결제 계정 관리자여야 한다.
resource "google_monitoring_notification_channel" "budget" {
  for_each     = var.billing_account != "" ? toset(var.budget_notification_emails) : toset([])
  display_name = "budget ${each.value}"
  type         = "email"

  labels = {
    email_address = each.value
  }

  depends_on = [google_project_service.this["monitoring.googleapis.com"]]
}

resource "google_billing_budget" "monthly" {
  count = var.billing_account != "" ? 1 : 0

  billing_account = var.billing_account
  display_name    = "${local.name}-monthly"

  budget_filter {
    projects = ["projects/${var.project_id}"]
  }

  amount {
    specified_amount {
      currency_code = "USD"
      units         = tostring(floor(var.budget_limit_usd))
    }
  }

  threshold_rules {
    threshold_percent = 0.8
  }

  threshold_rules {
    threshold_percent = 1.0
    spend_basis       = "FORECASTED_SPEND"
  }

  all_updates_rule {
    monitoring_notification_channels = [for c in google_monitoring_notification_channel.budget : c.id]
    disable_default_iam_recipients   = false
  }

  depends_on = [google_project_service.this["billingbudgets.googleapis.com"]]
}
