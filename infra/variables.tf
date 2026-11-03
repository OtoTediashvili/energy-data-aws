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
