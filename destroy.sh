#!/usr/bin/env bash
# Removes what setup.sh and the demo created: the kind cluster, Claude Code's KAOP
# connection, and the demo's agents, rules, schedule, budgets, Slack route and sink in KAOP.
# The Slack integration stays; disconnect it in Settings -> Integrations if you added it only
# for the demo. Run it from the repo root, in `devbox shell`.
set -euo pipefail
cd "$(dirname "$0")"

KAOP=https://agentops.komodor.com
RUNS=../kaop-runs
SINK_NAME="Slack approvals and run reports"
SCHEDULE_NAME="website-health-check"

: "${AGENTOPS_API_KEY:?Set AGENTOPS_API_KEY (setup.sh saved it to .env).}"

api() {
    curl --silent --fail-with-body --request "$1" "$KAOP$2" \
        --header "Authorization: Bearer $AGENTOPS_API_KEY" \
        --header "Content-Type: application/json"
}

agent_id() { api GET "/api/v1/agents?include_archived=true" | jq --raw-output --arg slug "$1" '.[] | select(.id_slug == $slug) | .agent_id'; }

REMEDIATOR_ID=$(agent_id kubernetes-remediator)

# The cluster goes first: KAOP deletes an agent only once its worker is offline.
kind delete cluster --name kaop

for id in $(api GET /api/v1/schedules | jq --raw-output --arg name "$SCHEDULE_NAME" '.[] | select(.name == $name) | .schedule_id'); do
    api DELETE "/api/v1/schedules/$id" >/dev/null && echo "Deleted the schedule."
done

for channel in $(api GET /api/v1/channels | jq --raw-output '.[] | select(.provider == "slack") | .id'); do
    for route in $(api GET "/api/v1/channels/$channel/routes" | jq --raw-output --arg id "$REMEDIATOR_ID" '.[]? | select(.target_id == $id) | .id'); do
        api DELETE "/api/v1/channels/$channel/routes/$route" >/dev/null && echo "Deleted the Slack route."
    done
done

for id in $(api GET /api/v1/notification-sinks | jq --raw-output --arg name "$SINK_NAME" '.[] | select(.name == $name) | .id'); do
    api DELETE "/api/v1/notification-sinks/$id" >/dev/null && echo "Deleted the Slack sink."
done

for slug in kubernetes-remediator dot-ai kubernetes-rca-kaop; do
    id=$(agent_id "$slug")
    [ -n "$id" ] || continue
    for budget in $(api GET "/api/v1/cost/agent-budgets/$id" | jq --raw-output '.[]? | .budget_id'); do
        api DELETE "/api/v1/cost/agent-budgets/$id/$budget" >/dev/null && echo "Deleted a budget on $slug."
    done
    api DELETE "/api/v1/action-permissions/agents/$id" >/dev/null 2>&1 && echo "Deleted the approval rule on $slug." || true
    # KAOP deletes only archived agents.
    api PATCH "/api/v1/agents/$id/archive" >/dev/null
    echo "Waiting for $slug's worker to go offline..."
    until api DELETE "/api/v1/agents/$id" >/dev/null 2>&1; do sleep 15; done
    echo "Deleted the agent $slug."
done

if [ -d "$RUNS/claude-code-kaop" ] && command -v claude >/dev/null; then
    (cd "$RUNS/claude-code-kaop" && claude mcp remove agentops >/dev/null 2>&1) || true
fi
rm -rf "$RUNS"
