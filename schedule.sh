#!/usr/bin/env bash
# Usage: ./schedule.sh on|off
# Turns the Kubernetes Remediator's five-minute health check (created by setup.sh) on or off.
set -euo pipefail
: "${AGENTOPS_API_KEY:?Set AGENTOPS_API_KEY (setup.sh saved it to .env).}"
case "${1:-}" in on) ENABLED=true ;; off) ENABLED=false ;; *) echo "Usage: $0 on|off"; exit 1 ;; esac
KAOP=https://agentops.komodor.com
api() {
    curl --silent --fail-with-body --request "$1" "$KAOP$2" \
        --header "Authorization: Bearer $AGENTOPS_API_KEY" \
        --header "Content-Type: application/json" ${3:+--data "$3"}
}
ID=$(api GET /api/v1/schedules | jq --raw-output '.[] | select(.name == "shop-health-check") | .schedule_id')
api PATCH "/api/v1/schedules/$ID" "{\"is_enabled\": $ENABLED}" \
    | jq --compact-output '{name, cron_expr, is_enabled, last_fired_at}'
