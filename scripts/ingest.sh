#!/usr/bin/env bash
# Run one zone's day through both functions, the way the state machine will:
# extract's output becomes parse's input.
#
#   scripts/ingest.sh NL 2026-10-30
#
# The date is the run's UTC day; without one, today's. ENTSO-E publishes the
# next day's prices around 11:00 UTC, and refuses a window that reaches a day
# it hasn't published, so before then, use yesterday.
set -euo pipefail
cd "$(dirname "$0")/.."

zone=${1:?usage: scripts/ingest.sh ZONE [YYYY-MM-DD]}
day=${2:-$(date -u +%F)}

eic=$(awk -F, -v zone="$zone" 'NR > 1 && $3 == zone { print $1 }' dbt/seeds/bidding_zones.csv)
if [[ -z $eic ]]; then
  echo "Unknown zone $zone. The zones are in dbt/seeds/bidding_zones.csv." >&2
  exit 1
fi

event=$(printf '{"zone": "%s", "eic": "%s", "logical_date": "%s"}' "$zone" "$eic" "$day")
response=$(mktemp)
trap 'rm -f "$response"' EXIT

for step in extract parse; do
  error=$(aws lambda invoke --function-name "energy-$step" \
    --cli-binary-format raw-in-base64-out --cli-read-timeout 300 \
    --payload "$event" --query FunctionError --output text "$response")
  if [[ $error != "None" ]]; then
    echo "energy-$step failed:" >&2
    cat "$response" >&2
    echo >&2
    exit 1
  fi
  echo "energy-$step: $(cat "$response")"
  event=$(cat "$response")
done
