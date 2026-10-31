provider "aws" {
  region = var.region

  # On every resource, so the bill and the console can be filtered by project.
  default_tags {
    tags = {
      project    = "energy-data-aws"
      managed-by = "terraform"
      stack      = "main"
    }
  }
}

data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
}
