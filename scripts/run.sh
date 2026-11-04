#!/usr/bin/env bash
# Start a state machine run and follow it to the end.
#
#   scripts/run.sh daily [YYYY-MM-DD]   one day for every zone, then dbt
#   scripts/run.sh backfill             parse all of landing/ again, then dbt
#
# Without a date, the daily run takes today (UTC), as the schedule does.
# Prints progress every 30 seconds and the result at the end; exits non-zero
# if the run didn't succeed. Ctrl+C stops this script, not the run: it
# carries on in AWS, and the console link shows it.
set -euo pipefail

usage="usage: scripts/run.sh daily [YYYY-MM-DD] | backfill"
machine=${1:?$usage}
day=${2:-}

case $machine in
  daily)
    input='{}'
    if [[ -n $day ]]; then
      if [[ ! $day =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        echo "The date must look like 2026-11-02, not '$day'." >&2
        exit 2
      fi
      input=$(printf '{"logical_date": "%s"}' "$day")
    fi
    ;;
  backfill) input='{}' ;;
  *)
    echo "$usage" >&2
    exit 2
    ;;
esac

region=${AWS_REGION:?AWS_REGION is not set}
account=$(aws sts get-caller-identity --query Account --output text)
arn="arn:aws:states:$region:$account:stateMachine:energy-$machine"

execution=$(aws stepfunctions start-execution --state-machine-arn "$arn" \
  --input "$input" --query executionArn --output text)
echo "Started ${execution##*:} on energy-$machine with $input"
echo "Follow it: https://$region.console.aws.amazon.com/states/home?region=$region#/v2/executions/details/$execution"

started=$SECONDS
while status=$(aws stepfunctions describe-execution --execution-arn "$execution" \
  --query status --output text) && [[ $status == RUNNING ]]; do
  sleep 30
  elapsed=$((SECONDS - started))
  printf 'still running, %dm %02ds\n' $((elapsed / 60)) $((elapsed % 60))
done

echo "$status"
if [[ $status == SUCCEEDED ]]; then
  aws stepfunctions describe-execution --execution-arn "$execution" \
    --query output --output text | python3 -m json.tool
else
  aws stepfunctions describe-execution --execution-arn "$execution" \
    --query '{error: error, cause: cause}' --output json
  exit 1
fi
