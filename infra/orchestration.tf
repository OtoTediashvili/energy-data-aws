# Orchestration: the state machines, the daily schedule, and an email when
# a run fails.
#
#   energy-daily     every zone's day: extract -> parse, then dbt. Started by
#                    EventBridge Scheduler every afternoon, or `make run`.
#   energy-backfill  parse everything in landing/ again, then dbt. Started
#                    by `make backfill`, after copying history to landing/.
#
# The definitions are in state_machines/, as JSON with JSONata expressions;
# tests/test_state_machines.py renders them and evaluates those expressions.

locals {
  state_machines = {
    daily    = "Every zone's prices for one day, then dbt."
    backfill = "Parse every landed file again, then dbt."
  }
  # Built from names, not from the resources, because the role's policy and
  # the state machines refer to each other.
  state_machine_arns = {
    for name in keys(local.state_machines) :
    name => "arn:aws:states:${var.region}:${local.account_id}:stateMachine:energy-${name}"
  }
  definitions = {
    daily = templatefile("${path.module}/state_machines/daily.asl.json", {
      extract   = aws_lambda_function.ingest["extract"].arn
      parse     = aws_lambda_function.ingest["parse"].arn
      transform = aws_lambda_function.transform.arn
      zones     = jsonencode([for zone in local.zones : { zone = zone.country_code, eic = zone.bidding_zone_eic }])
    })
    backfill = templatefile("${path.module}/state_machines/backfill.asl.json", {
      parse       = aws_lambda_function.ingest["parse"].arn
      transform   = aws_lambda_function.transform.arn
      bucket      = aws_s3_bucket.lake.bucket
      eic_by_zone = jsonencode({ for zone in local.zones : zone.country_code => zone.bidding_zone_eic })
    })
  }
}

# ---------------------------------------------------------- state machines

# /aws/vendedlogs/ keeps Step Functions within CloudWatch's limit on log
# resource policies, however many state machines log to it.
resource "aws_cloudwatch_log_group" "state_machine" {
  for_each = local.state_machines

  name              = "/aws/vendedlogs/states/energy-${each.key}"
  retention_in_days = 30
}

resource "aws_iam_role" "orchestrate" {
  name        = "energy-orchestrate"
  description = "What the state machines may do: run the three functions, list landing/, log."
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "states.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = { StringEquals = { "aws:SourceAccount" = local.account_id } }
    }]
  })
}

data "aws_iam_policy_document" "orchestrate" {
  statement {
    sid     = "RunTheFunctions"
    actions = ["lambda:InvokeFunction"]
    resources = [
      aws_lambda_function.ingest["extract"].arn,
      aws_lambda_function.ingest["parse"].arn,
      aws_lambda_function.transform.arn,
    ]
  }

  # The backfill's distributed map runs each file as a child execution.
  statement {
    sid       = "StartBackfillChildRuns"
    actions   = ["states:StartExecution"]
    resources = [local.state_machine_arns.backfill]
  }

  statement {
    sid     = "WatchBackfillChildRuns"
    actions = ["states:DescribeExecution", "states:StopExecution"]
    resources = [
      "arn:aws:states:${var.region}:${local.account_id}:execution:energy-backfill:*",
      "arn:aws:states:${var.region}:${local.account_id}:execution:energy-backfill/*",
    ]
  }

  statement {
    sid       = "ListLandedPrices"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.lake.arn]
    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["landing/dataset=prices/*"]
    }
  }

  # Step Functions delivers its logs through CloudWatch Logs' delivery API,
  # whose actions can't be limited to a resource.
  statement {
    sid = "DeliverLogs"
    actions = [
      "logs:CreateLogDelivery",
      "logs:GetLogDelivery",
      "logs:UpdateLogDelivery",
      "logs:DeleteLogDelivery",
      "logs:ListLogDeliveries",
      "logs:PutResourcePolicy",
      "logs:DescribeResourcePolicies",
      "logs:DescribeLogGroups",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "WriteTraces"
    actions   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords", "xray:GetSamplingRules", "xray:GetSamplingTargets"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "orchestrate" {
  name   = "orchestrate"
  role   = aws_iam_role.orchestrate.id
  policy = data.aws_iam_policy_document.orchestrate.json
}

resource "aws_sfn_state_machine" "pipeline" {
  for_each = local.state_machines

  name       = "energy-${each.key}"
  role_arn   = aws_iam_role.orchestrate.arn
  type       = "STANDARD"
  definition = local.definitions[each.key]

  # Every state's input and output, for a month: a run can be followed step
  # by step in the console. Nothing secret passes through: zones, dates, keys.
  logging_configuration {
    log_destination        = "${aws_cloudwatch_log_group.state_machine[each.key].arn}:*"
    include_execution_data = true
    level                  = "ALL"
  }

  tracing_configuration {
    enabled = true
  }

  depends_on = [aws_iam_role_policy.orchestrate]
}

# ------------------------------------------------------------- schedule

resource "aws_iam_role" "schedule" {
  name        = "energy-schedule"
  description = "Lets EventBridge Scheduler start the daily run, and nothing else."
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "scheduler.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = { StringEquals = { "aws:SourceAccount" = local.account_id } }
    }]
  })
}

resource "aws_iam_role_policy" "schedule" {
  name = "start-the-daily-run"
  role = aws_iam_role.schedule.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "states:StartExecution"
      Resource = aws_sfn_state_machine.pipeline["daily"].arn
    }]
  })
}

resource "aws_scheduler_schedule" "daily" {
  name        = "energy-daily"
  description = "Tomorrow's day-ahead prices, about an hour after the auction publishes them."

  schedule_expression          = var.daily_schedule
  schedule_expression_timezone = "Europe/Brussels"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_sfn_state_machine.pipeline["daily"].arn
    role_arn = aws_iam_role.schedule.arn
    # The time this run was due, not when it started: the state machine
    # takes its UTC day from it. A literal string, not jsonencode(), which
    # would escape the < > around the placeholder and the scheduler would
    # never fill it in.
    input = "{\"scheduled_time\": \"<aws.scheduler.scheduled-time>\"}"

    retry_policy {
      maximum_event_age_in_seconds = 3600
      maximum_retry_attempts       = 3
    }
  }
}

# --------------------------------------------------------------- alerts

resource "aws_sns_topic" "alerts" {
  name         = "energy-alerts"
  display_name = "energy-data-aws"
}

# AWS sends a confirmation email first; nothing arrives until it's clicked.
resource "aws_sns_topic_subscription" "alerts_email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

resource "aws_cloudwatch_event_rule" "run_failed" {
  name        = "energy-run-failed"
  description = "A daily or backfill run failed, timed out or was stopped."
  event_pattern = jsonencode({
    source        = ["aws.states"]
    "detail-type" = ["Step Functions Execution Status Change"]
    detail = {
      status          = ["FAILED", "TIMED_OUT", "ABORTED"]
      stateMachineArn = [for machine in aws_sfn_state_machine.pipeline : machine.arn]
    }
  })
}

data "aws_iam_policy_document" "alerts" {
  statement {
    sid       = "FailedRunsOnly"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.alerts.arn]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_cloudwatch_event_rule.run_failed.arn]
    }
  }
}

resource "aws_sns_topic_policy" "alerts" {
  arn    = aws_sns_topic.alerts.arn
  policy = data.aws_iam_policy_document.alerts.json
}

# The email names the error and links to the run in the console, where the
# failed state and its cause are one click away.
resource "aws_cloudwatch_event_target" "alerts_email" {
  rule = aws_cloudwatch_event_rule.run_failed.name
  arn  = aws_sns_topic.alerts.arn

  input_transformer {
    input_paths = {
      error     = "$.detail.error"
      execution = "$.detail.executionArn"
      name      = "$.detail.name"
      status    = "$.detail.status"
    }
    input_template = "\"Run <name> ended <status>, error <error>. What happened, step by step: https://${var.region}.console.aws.amazon.com/states/home?region=${var.region}#/v2/executions/details/<execution>\""
  }
}
