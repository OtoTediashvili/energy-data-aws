terraform {
  required_version = ">= 1.11"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # State lives in the bucket `make bootstrap` created. Its name contains the
  # account ID, so `make init` passes it in (-backend-config) rather than
  # writing it here. use_lockfile: S3's own lock files, no DynamoDB table.
  backend "s3" {
    key          = "energy-data-aws/main.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}
