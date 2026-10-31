#!/usr/bin/env bash
# Run one SQL statement in the project's Athena workgroup and print the rows.
#
#   scripts/athena_query.sh "SELECT 1"
#
# The workgroup decides where results go and how much a query may scan, so
# nothing here needs to know the bucket.
set -euo pipefail

sql=${1:?usage: scripts/athena_query.sh "SQL"}
workgroup=${ATHENA_WORKGROUP:-energy}

id=$(aws athena start-query-execution --work-group "$workgroup" \
  --query-string "$sql" --query QueryExecutionId --output text)

while :; do
  state=$(aws athena get-query-execution --query-execution-id "$id" \
    --query QueryExecution.Status.State --output text)
  case $state in
    SUCCEEDED) break ;;
    FAILED | CANCELLED)
      echo "Query $state:" >&2
      aws athena get-query-execution --query-execution-id "$id" \
        --query QueryExecution.Status.StateChangeReason --output text >&2
      exit 1
      ;;
  esac
  sleep 1
done

aws athena get-query-results --query-execution-id "$id" \
  --query 'ResultSet.Rows[*].Data[*].VarCharValue' --output text
scanned=$(aws athena get-query-execution --query-execution-id "$id" \
  --query QueryExecution.Statistics.DataScannedInBytes --output text)
echo "(query $id, scanned $scanned bytes)"
