# An email before the month's usage gets anywhere near real money.
#
# Credits are left out on purpose: while the Free plan's credits pay the
# bill, the net cost stays at zero and a budget that counted credits would
# never warn. This one measures what the account actually uses.

resource "aws_budgets_budget" "monthly" {
  name         = "energy-data-aws-monthly"
  budget_type  = "COST"
  limit_amount = format("%.2f", var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  cost_types {
    include_credit = false
    include_refund = false
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 50
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.alert_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.alert_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.alert_email]
  }
}

# Billing ignores resource tags until one is activated as a cost allocation
# tag. With this one, Cost Explorer can show what this project costs on its
# own (default_tags in providers.tf put it on every resource). Destroying it
# only deactivates the tag.
resource "aws_ce_cost_allocation_tag" "project" {
  tag_key = "project"
  status  = "Active"
}
