# Ingestion: two Lambda functions from one container image.
#
#   energy-extract  ENTSO-E -> landing/   one zone, one day: the raw XML
#   energy-parse    landing/ -> parsed/   that XML as typed Parquet
#
# Same split as project 1's extract and parse tasks: landing is the source of
# truth, and a parser fix is deployed and run again over it (the backfill
# state machine) without downloading anything. The daily state machine runs
# them per zone; scripts/ingest.sh runs one zone's day by hand.

locals {
  functions = {
    extract = {
      handler     = "energy.handlers.extract"
      description = "ENTSO-E day-ahead prices for one zone and day -> s3 landing/"
      memory      = 256
      # Up to four tries with backoff inside, each with a 30 s request timeout.
      timeout = 180
    }
    parse = {
      handler     = "energy.handlers.parse"
      description = "One landed ENTSO-E document -> typed Parquet in s3 parsed/"
      memory      = 512 # pyarrow
      timeout     = 60
    }
  }
}

# The images are pushed by `make image` before the plan; the digest pins each
# function to exactly that image. transform.tf uses the same repository.
data "aws_ecr_repository" "functions" {
  name = "energy-functions"
}

data "aws_ecr_image" "functions" {
  repository_name = data.aws_ecr_repository.functions.name
  image_tag       = var.image_tag
}

resource "aws_cloudwatch_log_group" "function" {
  for_each = local.functions

  name              = "/aws/lambda/energy-${each.key}"
  retention_in_days = 30
}

resource "aws_iam_role" "ingest" {
  name        = "energy-ingest"
  description = "What the extract and parse functions may do, and nothing else."
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# Least privilege, written out: the token, two prefixes of one bucket, their
# own log groups, and traces.
data "aws_iam_policy_document" "ingest" {
  statement {
    sid       = "ReadTheEntsoeToken"
    actions   = ["ssm:GetParameter"]
    resources = ["arn:aws:ssm:${var.region}:${local.account_id}:parameter${var.token_parameter}"]
  }

  statement {
    sid       = "WriteLandingAndParsed"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.lake.arn}/landing/*", "${aws_s3_bucket.lake.arn}/parsed/*"]
  }

  statement {
    sid       = "ReadLanding"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.lake.arn}/landing/*"]
  }

  # Without it, reading a day that was never landed is "Access Denied"
  # instead of "no such key", which sends you looking in the wrong place.
  statement {
    sid       = "ListTheLake"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.lake.arn]
  }

  statement {
    sid       = "WriteOwnLogs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = [for group in aws_cloudwatch_log_group.function : "${group.arn}:*"]
  }

  # X-Ray's write actions can't be limited to a resource.
  statement {
    sid       = "WriteTraces"
    actions   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "ingest" {
  name   = "ingest"
  role   = aws_iam_role.ingest.id
  policy = data.aws_iam_policy_document.ingest.json
}

resource "aws_lambda_function" "ingest" {
  for_each = local.functions

  function_name = "energy-${each.key}"
  description   = each.value.description
  role          = aws_iam_role.ingest.arn
  package_type  = "Image"
  image_uri     = "${data.aws_ecr_repository.functions.repository_url}@${data.aws_ecr_image.functions.image_digest}"
  architectures = ["x86_64"]
  memory_size   = each.value.memory
  timeout       = each.value.timeout

  image_config {
    command = [each.value.handler]
  }

  environment {
    variables = {
      ENERGY_LAKE_BUCKET     = aws_s3_bucket.lake.bucket
      ENERGY_TOKEN_PARAMETER = var.token_parameter
      ENERGY_LOG_JSON        = "true"
    }
  }

  tracing_config {
    mode = "Active"
  }

  # The log groups first, so Lambda never creates its own without a retention.
  depends_on = [aws_cloudwatch_log_group.function, aws_iam_role_policy.ingest]
}
