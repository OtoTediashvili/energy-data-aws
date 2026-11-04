#!/usr/bin/env bash
# AWS's own validator on both state machine definitions, rendered the way
# Terraform renders them (tests/test_state_machines.py, with stand-in ARNs).
# Free, and changes nothing: worth running before `make plan` whenever a
# definition changed, since a definition AWS rejects fails `make apply`.
set -euo pipefail
cd "$(dirname "$0")/.."

failed=0
for machine in daily backfill; do
  definition=$(uv run --quiet python -c \
    'import json, sys; from tests.test_state_machines import render; print(json.dumps(render(sys.argv[1])))' \
    "$machine")
  result=$(aws stepfunctions validate-state-machine-definition --type STANDARD \
    --definition "$definition" --query result --output text)
  echo "energy-$machine: $result"
  if [[ $result != OK ]]; then
    aws stepfunctions validate-state-machine-definition --type STANDARD \
      --definition "$definition" --query diagnostics --output table
    failed=1
  fi
done
exit $failed
