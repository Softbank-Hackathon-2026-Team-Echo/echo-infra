# 월 비용 알림 (NFR-13). 실제 비용 80% 와 예측 비용 100% 에서 메일을 보낸다.
# 받는 메일이 없으면 만들지 않는다 (AWS 루트와 같은 스위치). 메일이 있으면 billing_account 도 있어야 한다(variables.tf 검증).
# 적용하는 사람은 결제 계정 관리자여야 한다.
resource "google_monitoring_notification_channel" "budget" {
  for_each     = toset(var.budget_notification_emails)
  display_name = "budget ${each.value}"
  type         = "email"

  labels = {
    email_address = each.value
  }

  depends_on = [google_project_service.this["monitoring.googleapis.com"]]
}

resource "google_billing_budget" "monthly" {
  count = length(var.budget_notification_emails) > 0 ? 1 : 0

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
  }

  depends_on = [google_project_service.this["billingbudgets.googleapis.com"]]
}
