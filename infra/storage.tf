# The data lake: one bucket, one prefix per zone of the pipeline.
#
#   landing/         ENTSO-E's XML exactly as received, never modified
#   parsed/          one typed Parquet file per landed file
#   warehouse/       Iceberg tables written by dbt through Athena
#   athena-results/  query results; Athena needs somewhere to put them
#
# Same zones as project 1, on S3 instead of a laptop disk: each can be
# rebuilt from the one before, and landing from nothing but ENTSO-E.

resource "aws_s3_bucket" "lake" {
  bucket = "energy-lake-${local.account_id}"
}

# Landing is the source of truth. With versioning, an overwrite or a delete,
# by a bug or by hand, leaves the previous object recoverable for 30 days.
resource "aws_s3_bucket_versioning" "lake" {
  bucket = aws_s3_bucket.lake.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "lake" {
  bucket                  = aws_s3_bucket.lake.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "lake" {
  bucket = aws_s3_bucket.lake.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "lake" {
  bucket = aws_s3_bucket.lake.id

  # Query results are only needed while someone reads them.
  rule {
    id     = "athena-results"
    status = "Enabled"
    filter {
      prefix = "athena-results/"
    }
    expiration {
      days = 7
    }
    noncurrent_version_expiration {
      noncurrent_days = 1
    }
  }

  # Replaced and deleted objects: Iceberg's expired snapshots, overwritten
  # parsed files. Recoverable for 30 days, then gone, so versioning doesn't
  # quietly double the bill.
  rule {
    id     = "noncurrent-versions"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration {
      noncurrent_days = 30
    }
    expiration {
      expired_object_delete_marker = true
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.lake]
}

resource "aws_s3_bucket_policy" "lake" {
  bucket = aws_s3_bucket.lake.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [aws_s3_bucket.lake.arn, "${aws_s3_bucket.lake.arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })
  depends_on = [aws_s3_bucket_public_access_block.lake]
}
