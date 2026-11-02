# 월 비용 알림 (NFR-13). 실제 비용 80% 와 예측 비용 100% 에서 메일을 보낸다.
resource "aws_budgets_budget" "monthly" {
  name         = "${local.name}-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.budget_limit_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  dynamic "notification" {
    for_each = length(var.budget_notification_emails) > 0 ? [
      { type = "ACTUAL", threshold = 80 },
      { type = "FORECASTED", threshold = 100 },
    ] : []
    content {
      comparison_operator        = "GREATER_THAN"
      notification_type          = notification.value.type
      threshold                  = notification.value.threshold
      threshold_type             = "PERCENTAGE"
      subscriber_email_addresses = var.budget_notification_emails
    }
  }
}
