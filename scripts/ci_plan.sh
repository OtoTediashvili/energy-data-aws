#!/usr/bin/env bash
# Plan the main stack in CI, for the plan job and again for the apply job.
#
#   scripts/ci_plan.sh
#
# Writes the plan to infra/tfplan and its text to plan.txt, and gives the job
# two outputs (GITHUB_OUTPUT):
#   changes      true if applying the plan would change anything
#   fingerprint  a hash of what it changes: each resource and its actions
# The apply job can't be handed the plan job's file (it holds every value in
# plain text, and a public repository's run files are public), so it plans
# again and applies only if the fingerprint is the one I approved.
#
# Needs AWS credentials, an initialised infra/, and AWS_REGION.
set -euo pipefail

cd "$(dirname "$0")/.."
region=${AWS_REGION:?AWS_REGION is not set}

# -detailed-exitcode: 0 no changes, 1 error, 2 changes.
code=0
terraform -chdir=infra plan -input=false -no-color -lock-timeout=5m -detailed-exitcode \
  -var="region=${region}" -var="image_tag=$(scripts/image.sh tag)" -out=tfplan \
  | tee plan.txt || code=$?

case $code in
  0) changes=false ;;
  2) changes=true ;;
  *) exit "$code" ;;
esac

# Resource addresses and actions only, not values: values the plan can't know
# yet, or that AWS reports in another order, would make two equal plans differ.
fingerprint=$(
  terraform -chdir=infra show -json tfplan \
    | jq -c '[(.resource_changes // [])[]
              | select(.change.actions != ["no-op"])
              | {address, actions: .change.actions}]' \
    | sha256sum | cut -d' ' -f1
)

{
  echo "changes=${changes}"
  echo "fingerprint=${fingerprint}"
} >>"${GITHUB_OUTPUT:-/dev/null}"

{
  echo "### Terraform plan"
  grep -E '^(Plan:|No changes\.)' plan.txt || echo "No summary line found; see the log."
} >>"${GITHUB_STEP_SUMMARY:-/dev/null}"
