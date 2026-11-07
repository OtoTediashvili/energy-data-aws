# GitHub Actions on AWS, without a stored key.
#
# For each workflow run, GitHub signs a short-lived token that names the
# repository and the branch or environment the job runs for. AWS checks that
# signature (the OIDC provider below) and swaps the token for an hour of one
# role's credentials. There is no access key to leak or rotate.
#
# Two roles, so that a push alone can't change anything:
#
# - github-energy-plan: any job on main. Pushes the images, reads the state
#   and every resource of the main stack, and changes nothing else.
# - github-energy-apply: only a job in the GitHub environment `production`,
#   which waits for my approval. Changes the main stack's resources, and no
#   others.
#
# Both live in this stack, which only the laptop applies, so CI can't widen
# its own permissions. Their names don't start with "energy-" on purpose: the
# apply role manages roles named energy-*, and must not be able to manage
# itself.

# GitHub's token names the repository with its owner's and its own permanent
# IDs, not only their names ("immutable subject"): a repository deleted and
# created again under the same name gets a new ID, and so no access. The
# prefix comes from:
#   gh api repos/OtoTediashvili/energy-data-aws/actions/oidc/customization/sub
variable "github_subject_prefix" {
  description = "The start of the token's subject claim for the repository whose workflows may plan and deploy."
  type        = string
  default     = "repo:OtoTediashvili@142446890/energy-data-aws@1441335391"
}

variable "deploy_environment" {
  description = "The GitHub environment whose jobs may apply. It requires my approval."
  type        = string
  default     = "production"
}

locals {
  account_id = data.aws_caller_identity.current.account_id
  arn        = "${var.region}:${local.account_id}"

  # The token's subject claim: who is asking. A job that names an environment
  # is identified by the environment instead of the branch.
  ci_roles = {
    plan = {
      subject     = "${var.github_subject_prefix}:ref:refs/heads/main"
      description = "GitHub Actions on main: push the images, plan the main stack. Changes nothing else."
      policy      = data.aws_iam_policy_document.ci_plan.json
    }
    apply = {
      subject     = "${var.github_subject_prefix}:environment:${var.deploy_environment}"
      description = "GitHub Actions in the approved environment: apply the main stack, and only it."
      policy      = data.aws_iam_policy_document.ci_apply.json
    }
  }

  # What the main stack manages, by name.
  main_state     = "${aws_s3_bucket.state.arn}/energy-data-aws/main.tfstate"
  lake_bucket    = "arn:aws:s3:::energy-lake-${local.account_id}"
  workload_roles = "arn:aws:iam::${local.account_id}:role/energy-*"
  functions      = "arn:aws:lambda:${local.arn}:function:energy-*"
  log_groups = [
    "arn:aws:logs:${local.arn}:log-group:/aws/lambda/energy-*",
    "arn:aws:logs:${local.arn}:log-group:/aws/vendedlogs/states/energy-*",
  ]
  state_machines = "arn:aws:states:${local.arn}:stateMachine:energy-*"
  schedules      = "arn:aws:scheduler:${local.arn}:schedule/default/energy-*"
  topics         = "arn:aws:sns:${local.arn}:energy-*"
  rules          = "arn:aws:events:${local.arn}:rule/energy-*"
  glue_catalog   = "arn:aws:glue:${local.arn}:catalog"
  glue_databases = "arn:aws:glue:${local.arn}:database/energy_*"
  workgroup      = "arn:aws:athena:${local.arn}:workgroup/energy"
  budgets        = "arn:aws:budgets::${local.account_id}:budget/energy-data-aws-*"
}

# GitHub's token issuer. AWS verifies its certificates itself, so there is no
# thumbprint to pin.
resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

data "aws_iam_policy_document" "ci_trust" {
  for_each = local.ci_roles

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Exactly this repository and this branch or environment: no wildcard, so
    # no other repository, branch, pull request or fork qualifies.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = [each.value.subject]
    }
  }
}

resource "aws_iam_role" "ci" {
  for_each = local.ci_roles

  name               = "github-energy-${each.key}"
  description        = each.value.description
  assume_role_policy = data.aws_iam_policy_document.ci_trust[each.key].json
}

resource "aws_iam_role_policy" "ci" {
  for_each = local.ci_roles

  name   = each.key
  role   = aws_iam_role.ci[each.key].id
  policy = each.value.policy
}

# ---------------------------------------------------------------- plan

data "aws_iam_policy_document" "ci_plan" {
  statement {
    sid       = "ListTheStateBucket"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.state.arn]
  }

  statement {
    sid       = "ReadTheMainState"
    actions   = ["s3:GetObject"]
    resources = [local.main_state]
  }

  # A plan holds the state's lock file while it runs, so two runs can't
  # interleave.
  statement {
    sid       = "LockTheMainState"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${local.main_state}.tflock"]
  }

  # The registry's login has no resource of its own.
  statement {
    sid       = "LogInToTheRegistry"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  # Tags are immutable and name the content, so a push adds an image and can
  # never replace one a function runs.
  statement {
    sid = "PushTheImages"
    actions = [
      "ecr:DescribeRepositories",
      "ecr:DescribeImages",
      "ecr:ListTagsForResource",
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
    ]
    resources = [aws_ecr_repository.functions.arn]
  }

  statement {
    sid       = "ReadTheWorkloadRoles"
    actions   = ["iam:GetRole", "iam:GetRolePolicy", "iam:ListRolePolicies", "iam:ListAttachedRolePolicies"]
    resources = [local.workload_roles]
  }

  statement {
    sid       = "ReadTheFunctions"
    actions   = ["lambda:GetFunction*", "lambda:GetPolicy", "lambda:ListVersionsByFunction", "lambda:ListTags"]
    resources = [local.functions]
  }

  # Terraform finds a log group by listing them; only names and settings.
  statement {
    sid       = "FindTheLogGroups"
    actions   = ["logs:DescribeLogGroups"]
    resources = ["arn:aws:logs:${local.arn}:log-group:*"]
  }

  statement {
    sid       = "ReadTheLogGroups"
    actions   = ["logs:ListTagsForResource", "logs:ListTagsLogGroup"]
    resources = local.log_groups
  }

  statement {
    sid       = "ReadTheStateMachines"
    actions   = ["states:DescribeStateMachine", "states:ListStateMachineVersions", "states:ListTagsForResource"]
    resources = [local.state_machines]
  }

  statement {
    sid       = "ReadTheSchedule"
    actions   = ["scheduler:GetSchedule"]
    resources = [local.schedules]
  }

  # A subscription's ARN is its topic's ARN plus an ID, so it matches too.
  statement {
    sid = "ReadTheAlerts"
    actions = [
      "sns:GetTopicAttributes",
      "sns:ListTagsForResource",
      "sns:ListSubscriptionsByTopic",
      "sns:GetSubscriptionAttributes",
    ]
    resources = [local.topics]
  }

  statement {
    sid       = "ReadTheFailureRule"
    actions   = ["events:DescribeRule", "events:ListTargetsByRule", "events:ListTagsForResource"]
    resources = [local.rules]
  }

  # The bucket's settings, not its objects: object ARNs end in /key.
  statement {
    sid = "ReadTheLakeSettings"
    actions = [
      "s3:ListBucket",
      "s3:GetBucket*",
      "s3:GetAccelerateConfiguration",
      "s3:GetEncryptionConfiguration",
      "s3:GetLifecycleConfiguration",
      "s3:GetReplicationConfiguration",
    ]
    resources = [local.lake_bucket]
  }

  statement {
    sid       = "ReadTheCatalog"
    actions   = ["glue:GetDatabase", "glue:GetTable", "glue:GetTags"]
    resources = [local.glue_catalog, local.glue_databases, "arn:aws:glue:${local.arn}:table/energy_*/*"]
  }

  statement {
    sid       = "ReadTheWorkgroup"
    actions   = ["athena:GetWorkGroup", "athena:ListTagsForResource"]
    resources = [local.workgroup]
  }

  statement {
    sid       = "ReadTheBudget"
    actions   = ["budgets:ViewBudget", "budgets:ListTagsForResource"]
    resources = [local.budgets]
  }
}

# --------------------------------------------------------------- apply

# Everything plan may do (apply plans again first), and the changes.
data "aws_iam_policy_document" "ci_apply" {
  source_policy_documents = [data.aws_iam_policy_document.ci_plan.json]

  statement {
    sid       = "WriteTheMainState"
    actions   = ["s3:PutObject"]
    resources = [local.main_state]
  }

  statement {
    sid = "ManageTheWorkloadRoles"
    actions = [
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:UpdateRole",
      "iam:UpdateRoleDescription",
      "iam:UpdateAssumeRolePolicy",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:ListInstanceProfilesForRole",
    ]
    resources = [local.workload_roles]
  }

  # Each workload role goes only to the service it was written for.
  statement {
    sid       = "HandTheWorkloadRolesToTheirServices"
    actions   = ["iam:PassRole"]
    resources = [local.workload_roles]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["lambda.amazonaws.com", "states.amazonaws.com", "scheduler.amazonaws.com"]
    }
  }

  statement {
    sid = "ManageTheFunctions"
    actions = [
      "lambda:CreateFunction",
      "lambda:UpdateFunctionCode",
      "lambda:UpdateFunctionConfiguration",
      "lambda:DeleteFunction",
      "lambda:TagResource",
      "lambda:UntagResource",
    ]
    resources = [local.functions]
  }

  # Lambda reads a function's image with the caller's permissions.
  statement {
    sid       = "LetLambdaPullTheImages"
    actions   = ["ecr:GetDownloadUrlForLayer", "ecr:GetRepositoryPolicy"]
    resources = [aws_ecr_repository.functions.arn]
  }

  statement {
    sid = "ManageTheLogGroups"
    actions = [
      "logs:CreateLogGroup",
      "logs:DeleteLogGroup",
      "logs:PutRetentionPolicy",
      "logs:DeleteRetentionPolicy",
      "logs:TagResource",
      "logs:UntagResource",
      "logs:TagLogGroup",
      "logs:UntagLogGroup",
    ]
    resources = local.log_groups
  }

  # A state machine's logging is set up through log deliveries, which have no
  # resource of their own: the orchestrate role's DeliverLogs, for the caller.
  statement {
    sid = "SetUpStateMachineLogging"
    actions = [
      "logs:CreateLogDelivery",
      "logs:GetLogDelivery",
      "logs:UpdateLogDelivery",
      "logs:DeleteLogDelivery",
      "logs:ListLogDeliveries",
      "logs:PutResourcePolicy",
      "logs:DescribeResourcePolicies",
    ]
    resources = ["*"]
  }

  statement {
    sid = "ManageTheStateMachines"
    actions = [
      "states:CreateStateMachine",
      "states:UpdateStateMachine",
      "states:DeleteStateMachine",
      "states:TagResource",
      "states:UntagResource",
    ]
    resources = [local.state_machines]
  }

  statement {
    sid       = "ManageTheSchedule"
    actions   = ["scheduler:CreateSchedule", "scheduler:UpdateSchedule", "scheduler:DeleteSchedule"]
    resources = [local.schedules]
  }

  statement {
    sid = "ManageTheAlerts"
    actions = [
      "sns:CreateTopic",
      "sns:DeleteTopic",
      "sns:SetTopicAttributes",
      "sns:TagResource",
      "sns:UntagResource",
      "sns:Subscribe",
      "sns:Unsubscribe",
      "sns:SetSubscriptionAttributes",
    ]
    resources = [local.topics]
  }

  statement {
    sid = "ManageTheFailureRule"
    actions = [
      "events:PutRule",
      "events:DeleteRule",
      "events:PutTargets",
      "events:RemoveTargets",
      "events:TagResource",
      "events:UntagResource",
    ]
    resources = [local.rules]
  }

  statement {
    sid = "ManageTheLakeSettings"
    actions = [
      "s3:CreateBucket",
      "s3:DeleteBucket",
      "s3:PutBucketVersioning",
      "s3:PutBucketPublicAccessBlock",
      "s3:PutEncryptionConfiguration",
      "s3:PutLifecycleConfiguration",
      "s3:PutBucketPolicy",
      "s3:DeleteBucketPolicy",
      "s3:PutBucketTagging",
    ]
    resources = [local.lake_bucket]
  }

  # The raw table only: the tables in staging and marts are dbt's.
  statement {
    sid = "ManageTheCatalog"
    actions = [
      "glue:CreateDatabase",
      "glue:UpdateDatabase",
      "glue:DeleteDatabase",
      "glue:CreateTable",
      "glue:UpdateTable",
      "glue:DeleteTable",
      "glue:TagResource",
      "glue:UntagResource",
    ]
    resources = [local.glue_catalog, local.glue_databases, "arn:aws:glue:${local.arn}:table/energy_raw/*"]
  }

  statement {
    sid = "ManageTheWorkgroup"
    actions = [
      "athena:CreateWorkGroup",
      "athena:UpdateWorkGroup",
      "athena:DeleteWorkGroup",
      "athena:TagResource",
      "athena:UntagResource",
    ]
    resources = [local.workgroup]
  }

  statement {
    sid       = "ManageTheBudget"
    actions   = ["budgets:ModifyBudget", "budgets:TagResource", "budgets:UntagResource"]
    resources = [local.budgets]
  }
}

output "ci_roles" {
  description = "The roles the workflows assume (aws-actions/configure-aws-credentials, role-to-assume)."
  value       = { for name, role in aws_iam_role.ci : name => role.arn }
}
