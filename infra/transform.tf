# Transform: dbt build in a Lambda function, from the transform image.
#
# The same dbt project as `make dbt-build` on the laptop, run by the state
# machine after each day's deliveries. The function's role can run queries in
# the energy workgroup, read the raw layer, and write only what dbt builds:
# the staging and marts databases, and its seed in raw. It can't touch
# landing/ or parsed/, or the raw table Terraform owns.

locals {
  glue_catalog = "arn:aws:glue:${var.region}:${local.account_id}:catalog"
  glue_tables  = "arn:aws:glue:${var.region}:${local.account_id}:table"
  dbt_layers   = [aws_glue_catalog_database.layer["staging"].name, aws_glue_catalog_database.layer["marts"].name]
}

data "aws_ecr_image" "transform" {
  repository_name = data.aws_ecr_repository.functions.name
  image_tag       = "${var.image_tag}-transform"
}

resource "aws_cloudwatch_log_group" "transform" {
  name              = "/aws/lambda/energy-transform"
  retention_in_days = 30
}

resource "aws_iam_role" "transform" {
  name        = "energy-transform"
  description = "What the dbt function may do: queries in the energy workgroup, the tables dbt builds."
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

data "aws_iam_policy_document" "transform" {
  statement {
    sid = "RunQueriesInTheWorkgroup"
    actions = [
      "athena:GetWorkGroup",
      "athena:StartQueryExecution",
      "athena:GetQueryExecution",
      "athena:GetQueryResults",
      "athena:StopQueryExecution",
    ]
    resources = [aws_athena_workgroup.energy.arn]
  }

  # dbt lists the databases to find its schemas; only names and settings.
  statement {
    sid       = "SeeTheDatabases"
    actions   = ["glue:GetDatabase", "glue:GetDatabases"]
    resources = [local.glue_catalog, "arn:aws:glue:${var.region}:${local.account_id}:database/*"]
  }

  statement {
    sid     = "ReadTheLayersTables"
    actions = ["glue:GetTable", "glue:GetTables", "glue:GetPartition", "glue:GetPartitions", "glue:BatchGetPartition"]
    resources = concat(
      [local.glue_catalog],
      [for db in aws_glue_catalog_database.layer : db.arn],
      [for db in aws_glue_catalog_database.layer : "${local.glue_tables}/${db.name}/*"],
    )
  }

  # Creating, renaming and dropping tables is how dbt builds them on Athena.
  statement {
    sid = "BuildDbtsTables"
    actions = [
      "glue:CreateTable",
      "glue:UpdateTable",
      "glue:DeleteTable",
      "glue:GetTableVersions",
      "glue:DeleteTableVersion",
      "glue:BatchDeleteTableVersion",
      "glue:CreatePartition",
      "glue:BatchCreatePartition",
      "glue:UpdatePartition",
      "glue:DeletePartition",
      "glue:BatchDeletePartition",
    ]
    resources = concat(
      [local.glue_catalog],
      [for name in local.dbt_layers : "arn:aws:glue:${var.region}:${local.account_id}:database/${name}"],
      [for name in local.dbt_layers : "${local.glue_tables}/${name}/*"],
      # The seed in raw, next to the table Terraform owns: dbt uploads the CSV
      # as bidding_zones__dbt_tmp, then builds bidding_zones from it.
      [aws_glue_catalog_database.layer["raw"].arn, "${local.glue_tables}/${aws_glue_catalog_database.layer["raw"].name}/bidding_zones*"],
    )
  }

  statement {
    sid       = "ListTheLake"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation", "s3:ListBucketMultipartUploads"]
    resources = [aws_s3_bucket.lake.arn]
  }

  statement {
    sid       = "ReadParsed"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.lake.arn}/parsed/*"]
  }

  # Athena writes query results, and dbt's tables, with the caller's rights.
  statement {
    sid = "WriteTablesAndResults"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:AbortMultipartUpload",
      "s3:ListMultipartUploadParts",
    ]
    resources = ["${aws_s3_bucket.lake.arn}/warehouse/*", "${aws_s3_bucket.lake.arn}/athena-results/*"]
  }

  statement {
    sid       = "WriteOwnLogs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.transform.arn}:*"]
  }

  # X-Ray's write actions can't be limited to a resource.
  statement {
    sid       = "WriteTraces"
    actions   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "transform" {
  name   = "transform"
  role   = aws_iam_role.transform.id
  policy = data.aws_iam_policy_document.transform.json
}

resource "aws_lambda_function" "transform" {
  function_name = "energy-transform"
  description   = "dbt build on Athena: staging, the zone dimension, daily prices; data tests"
  role          = aws_iam_role.transform.arn
  package_type  = "Image"
  image_uri     = "${data.aws_ecr_repository.functions.repository_url}@${data.aws_ecr_image.transform.image_digest}"
  architectures = ["x86_64"]
  # A build takes one to three minutes, nearly all of it waiting on Athena.
  memory_size = 1024
  timeout     = 900

  image_config {
    command = ["energy.transform.handler"]
  }

  environment {
    variables = {
      ENERGY_LAKE_BUCKET = aws_s3_bucket.lake.bucket
      ENERGY_LOG_JSON    = "true"
    }
  }

  tracing_config {
    mode = "Active"
  }

  depends_on = [aws_cloudwatch_log_group.transform, aws_iam_role_policy.transform]
}
