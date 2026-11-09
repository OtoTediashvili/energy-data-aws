# The most any workload role (energy-*) may ever do: this project's
# resources, and nothing in IAM.
#
# The apply role (ci.tf) creates and changes the energy-* roles, and could
# write any policy into them. A permissions boundary caps a role: what it may
# do is what both its own policy and the boundary allow. The apply role may
# only create or change a role that carries this boundary, and may not take
# it off, so a role it writes can't reach past this project, whatever its
# policy says.
#
# It lives here, in the stack only the laptop applies, so CI can't loosen it.
# Each role's own policy (main stack) stays the real least privilege; this is
# the ceiling above them all, so it is wider than any one role needs.
#
# A new AWS action in a workload role must be added here too, or it is
# denied even though the role's policy allows it.

locals {
  boundary_name = "energy-workload-boundary"
  token         = "arn:aws:ssm:${local.arn}:parameter/energy/*"
  glue_tables   = "arn:aws:glue:${local.arn}:table/energy_*/*"
}

data "aws_iam_policy_document" "workload_boundary" {
  statement {
    sid       = "ReadTheEntsoeToken"
    actions   = ["ssm:GetParameter"]
    resources = [local.token]
  }

  # The token is a SecureString under the AWS managed key aws/ssm, whose key
  # policy lets SSM decrypt it for the account's roles.
  statement {
    sid       = "DecryptTheTokenThroughSsm"
    actions   = ["kms:Decrypt"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.${var.region}.amazonaws.com"]
    }
  }

  statement {
    sid       = "UseTheLakeBucket"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation", "s3:ListBucketMultipartUploads"]
    resources = [local.lake_bucket]
  }

  statement {
    sid = "UseTheLakeObjects"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:AbortMultipartUpload",
      "s3:ListMultipartUploadParts",
    ]
    resources = ["${local.lake_bucket}/*"]
  }

  # dbt lists every database to find its schemas: names and settings only.
  statement {
    sid       = "SeeTheDatabases"
    actions   = ["glue:GetDatabase", "glue:GetDatabases"]
    resources = [local.glue_catalog, "arn:aws:glue:${local.arn}:database/*"]
  }

  statement {
    sid = "UseTheProjectsTables"
    actions = [
      "glue:GetTable",
      "glue:GetTables",
      "glue:CreateTable",
      "glue:UpdateTable",
      "glue:DeleteTable",
      "glue:GetTableVersions",
      "glue:DeleteTableVersion",
      "glue:BatchDeleteTableVersion",
      "glue:GetPartition",
      "glue:GetPartitions",
      "glue:BatchGetPartition",
      "glue:CreatePartition",
      "glue:BatchCreatePartition",
      "glue:UpdatePartition",
      "glue:DeletePartition",
      "glue:BatchDeletePartition",
    ]
    resources = [local.glue_catalog, local.glue_databases, local.glue_tables]
  }

  statement {
    sid = "RunQueriesInTheWorkgroup"
    actions = [
      "athena:GetWorkGroup",
      "athena:StartQueryExecution",
      "athena:GetQueryExecution",
      "athena:GetQueryResults",
      "athena:StopQueryExecution",
    ]
    resources = [local.workgroup]
  }

  statement {
    sid       = "RunTheFunctions"
    actions   = ["lambda:InvokeFunction"]
    resources = [local.functions]
  }

  # Executions and the backfill's child runs: execution:energy-<name>:<id>
  # and execution:energy-<name>/<map run>:<id>.
  statement {
    sid       = "RunTheStateMachines"
    actions   = ["states:StartExecution"]
    resources = [local.state_machines]
  }

  statement {
    sid       = "WatchTheRuns"
    actions   = ["states:DescribeExecution", "states:StopExecution"]
    resources = ["arn:aws:states:${local.arn}:execution:energy-*"]
  }

  statement {
    sid       = "WriteOwnLogs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = [for group in local.log_groups : "${group}:*"]
  }

  # Step Functions' log delivery and X-Ray's writes can't be limited to a
  # resource (as in the roles' own policies).
  statement {
    sid = "DeliverStateMachineLogs"
    actions = [
      "logs:CreateLogDelivery",
      "logs:GetLogDelivery",
      "logs:UpdateLogDelivery",
      "logs:DeleteLogDelivery",
      "logs:ListLogDeliveries",
      "logs:PutResourcePolicy",
      "logs:DescribeResourcePolicies",
      "logs:DescribeLogGroups",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "WriteTraces"
    actions   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords", "xray:GetSamplingRules", "xray:GetSamplingTargets"]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "workload_boundary" {
  name        = local.boundary_name
  description = "The ceiling for every energy-* role: this project's resources, nothing in IAM."
  policy      = data.aws_iam_policy_document.workload_boundary.json
}

output "workload_boundary" {
  description = "The permissions boundary every energy-* role must carry (main stack, permissions_boundary)."
  value       = aws_iam_policy.workload_boundary.arn
}
