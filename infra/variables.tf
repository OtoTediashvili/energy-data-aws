variable "region" {
  description = "AWS Region for everything. Frankfurt: close to ENTSO-E and to Tbilisi."
  type        = string
  default     = "eu-central-1"
}

variable "alert_email" {
  description = "Where budget alerts and failed-run alerts go. Kept in terraform.tfvars (gitignored) and, for CI, in the ALERT_EMAIL secret."
  type        = string
  # Plans are printed in public CI logs: show "(sensitive value)" instead.
  sensitive = true

  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.alert_email))
    error_message = "alert_email must be an email address."
  }
}

variable "monthly_budget_usd" {
  description = "Alert when the month's usage passes or is forecast to pass this, in USD."
  type        = number
  default     = 5
}

variable "athena_scan_limit_bytes" {
  description = <<-EOT
    Athena cancels any query in the workgroup that scans more than this.
    Athena bills per terabyte scanned (at least 10 MB per query), so this
    caps what a runaway query can cost. The whole dataset is a few megabytes;
    1 GiB leaves room for years of growth.
  EOT
  type        = number
  default     = 1073741824

  validation {
    condition     = var.athena_scan_limit_bytes >= 10485760
    error_message = "Athena's smallest allowed limit is 10 MB (10485760 bytes)."
  }
}

variable "image_tag" {
  description = "The functions' image in ECR, tagged by content: `make plan` passes scripts/image.sh's tag."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-f]{12}$", var.image_tag))
    error_message = "image_tag is the 12-character content hash scripts/image.sh prints."
  }
}

variable "token_parameter" {
  description = "SSM parameter (SecureString) holding the ENTSO-E token. Created by hand, never by Terraform, so the token stays out of the state file."
  type        = string
  default     = "/energy/entsoe/token"
}

variable "daily_schedule" {
  description = <<-EOT
    When the daily run starts, as an EventBridge Scheduler cron expression in
    Brussels time, the auction's own clock. Tomorrow's prices are usually out
    by 13:00; this leaves an hour, and the run waits up to 2 h 20 more for a
    late publication before it fails.
  EOT
  type        = string
  default     = "cron(17 14 * * ? *)"

  validation {
    condition     = can(regex("^cron\\(.+\\)$", var.daily_schedule))
    error_message = "daily_schedule is a cron(...) expression, e.g. cron(17 14 * * ? *)."
  }
}
