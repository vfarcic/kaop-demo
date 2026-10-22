#!/usr/bin/env bash
# Usage: summary.sh <results-dir>
# One line per run saved by batch.sh: model, duration, turns, cost, report, endpoints and checkouts afterwards.
set -euo pipefail
cd "$1"
for C in claude-code claude-code-kaop-only; do
  for I in 1 2 3; do
    D="$C/iter-$I"
    MODEL=$(jq -r 'select(.type=="system" and .subtype=="init") | .model' "$D/run.jsonl" | head -1)
    STATS=$(tail -1 "$D/run.jsonl" | jq -c '{d: .duration_ms, t: .num_turns, c: (.total_cost_usd * 100 | round / 100)}')
    REPORT=$([ -s "$D/report.md" ] && echo yes || echo no)
    ENDPOINTS=$(awk '$1=="orders" {print split($2, e, ",")}' "$D/after-endpoints.txt")
    AFTER=$(tr -s ' \n' ' ' < "$D/after-30s-statuses.txt")
    echo "$C #$I model=$MODEL $STATS report=$REPORT endpoints=$ENDPOINTS after=[$AFTER]"
  done
done
