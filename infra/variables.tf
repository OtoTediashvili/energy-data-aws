variable "region" {
  description = "AWS Region for everything. Frankfurt: close to ENTSO-E and to Tbilisi."
  type        = string
  default     = "eu-central-1"
}

variable "alert_email" {
  description = "Where budget alerts go. Kept in terraform.tfvars, which is gitignored."
  type        = string

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
