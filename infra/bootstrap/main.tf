# What has to exist before the main stack can be planned:
#
# - the bucket that holds the main stack's Terraform state, and
# - the container registry for the functions' image. A Lambda function can
#   only be created from an image that is already in the registry, so the
#   registry comes first, then `make image` pushes, then the main stack.
#
# Applied by `make bootstrap`, with local state (terraform.tfstate in this
# folder, gitignored): a state bucket can't keep its own state before it
# exists. Everything else keeps its state in that bucket, locked with S3's
# native lock files, so there is no DynamoDB table to pay for.

terraform {
  required_version = ">= 1.11"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

variable "region" {
  type    = string
  default = "eu-central-1"
}

provider "aws" {
  region = var.region
  default_tags {
    tags = {
      project    = "energy-data-aws"
      managed-by = "terraform"
      stack      = "bootstrap"
    }
  }
}

data "aws_caller_identity" "current" {}

resource "aws_s3_bucket" "state" {
  # The account ID makes the name globally unique and keeps it out of code.
  bucket = "energy-tfstate-${data.aws_caller_identity.current.account_id}"

  # Losing this bucket loses track of every resource Terraform manages.
  lifecycle {
    prevent_destroy = true
  }
}

# Every state write is a new version: a bad apply can be rolled back.
resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    id     = "old-state-versions"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration {
      noncurrent_days = 90
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# State holds resource details; only HTTPS may read or write it.
resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [aws_s3_bucket.state.arn, "${aws_s3_bucket.state.arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })
  depends_on = [aws_s3_bucket_public_access_block.state]
}

# The functions' image. Tags are immutable and name the image's content
# (scripts/image.sh), so a tag always means the same code. Every push is
# scanned for known vulnerabilities, and only the newest ten images are kept.
resource "aws_ecr_repository" "functions" {
  name                 = "energy-functions"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }
}

resource "aws_ecr_lifecycle_policy" "functions" {
  repository = aws_ecr_repository.functions.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep the newest ten images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = { type = "expire" }
    }]
  })
}

output "state_bucket" {
  value = aws_s3_bucket.state.bucket
}

output "functions_repository" {
  value = aws_ecr_repository.functions.repository_url
}
