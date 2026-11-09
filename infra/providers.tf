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

  # Every energy-* role carries it: the most a role may do, whatever its own
  # policy says. Made and owned by the bootstrap stack (boundary.tf there); CI
  # may create or change a role only with it on.
  workload_boundary = "arn:aws:iam::${local.account_id}:policy/energy-workload-boundary"
}
