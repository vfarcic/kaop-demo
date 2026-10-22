#!/usr/bin/env bash
# Sets up everything the demo needs: a kind cluster with the shop app; KAOP's
# Kubernetes RCA, the Shop Remediator and dot-ai in it; the approval rules, Slack,
# a schedule, and Claude Code connected to KAOP. Asks for what it can't find, and
# saves the answers to .env (gitignored; `devbox shell` loads it) so a re-run
# doesn't ask again. Run it from the repo root, in `devbox shell`. Safe to re-run.
set -euo pipefail
cd "$(dirname "$0")"
export KUBECONFIG="${KUBECONFIG:-$PWD/kubeconfig.yaml}"

KAOP=https://agentops.komodor.com
CHART=oci://ghcr.io/komodorio/charts/agentops-agent-base
CHART_VERSION=0.1.2202
REMEDIATOR_IMAGE=kaop-remediator:0.1.2202-kubectl1.36.3
DOT_AI_WORKER_IMAGE=kaop-dot-ai-worker:0.1.2202-1
RUNS=../kaop-runs
SINK_NAME="Slack approvals and run reports"
SCHEDULE_NAME="shop-health-check"

step() { printf '\n== %s\n' "$*"; }

# ask VAR "question" "how to find it" [secret]
ask() {
    local var=$1 question=$2 help=$3 secret=${4:-} value
    if [ -n "${!var:-}" ]; then return; fi
    printf '\n%s\n' "$help"
    if [ -n "$secret" ]; then
        read -r -s -p "$question: " value
        echo
    else
        read -r -p "$question: " value
    fi
    [ -n "$value" ] || { echo "$var is required."; exit 1; }
    export "$var=$value"
    touch .env
    chmod 600 .env
    printf 'export %s=%q\n' "$var" "$value" >> .env
}

pause() { read -r -p "$1 Press Enter when done. "; }

# api METHOD PATH [BODY_FILE]: KAOP's REST API; prints the response body, fails on HTTP errors.
api() {
    local out status
    out=$(mktemp)
    status=$(curl --silent --output "$out" --write-out '%{http_code}' --request "$1" "$KAOP$2" \
        --header "Authorization: Bearer $AGENTOPS_API_KEY" \
        --header "Content-Type: application/json" \
        ${3:+--data "@$3"})
    if [ "$status" -ge 400 ]; then
        echo "KAOP API $1 $2 returned HTTP $status:" >&2
        cat "$out" >&2
        rm -f "$out"
        return 1
    fi
    cat "$out"
    rm -f "$out"
}

agent_id() { api GET /api/v1/agents | jq --raw-output --arg slug "$1" '.[] | select(.id_slug == $slug) | .agent_id'; }

# worker_token AGENT SECRET [CATALOG_BODY]: a fresh worker token for the agent, stored as a
# Secret in kaop without being printed. A catalog agent that doesn't exist yet is registered first.
worker_token() {
    local body
    if [ -z "$(agent_id "$1")" ] && [ -n "${3:-}" ]; then
        body=$(api POST /api/v1/worker-catalog/kubernetes-rca/self-hosted-deploy <(echo "$3"))
    else
        body=$(jq --null-input --arg id "$1" '{agentId: $id, credentialRef: "LLM_PROXY_TOKEN"}' \
            | api POST /api/v1/agents/worker-token /dev/stdin)
    fi
    jq --join-output .token <<<"$body" | kubectl --namespace kaop create secret generic "$2" \
        --from-file token=/dev/stdin --dry-run=client --output yaml | kubectl apply --filename - >/dev/null
# The shop namespace comes first: the agents' Roles live in it.
kubectl apply --filename k8s/app.yaml >/dev/null
}

# install RELEASE VALUES: installs a worker with Komodor's chart and restarts it to pick up a new token.
install() {
    helm upgrade --install "$1" "$CHART" --version "$CHART_VERSION" \
        --namespace kaop --values "$2" --wait >/dev/null
    kubectl --namespace kaop rollout restart deployment --selector "app.kubernetes.io/instance=$1" >/dev/null
    kubectl --namespace kaop rollout status deployment --selector "app.kubernetes.io/instance=$1" >/dev/null
}

# permission AGENT FILE: the agent's approval rule, sent to Slack, with you as the approver.
permission() {
    local id
    id=$(jq --arg sink "$SINK_ID" '.notification_sink_id = $sink' "$2" \
        | api PUT "/api/v1/action-permissions/agents/$1" /dev/stdin | jq --raw-output .id)
    jq --null-input --arg me "$PRINCIPAL_ID" '{principal_ids: [$me]}' \
        | api PUT "/api/v1/authz/action-permissions/$id/approvers" /dev/stdin >/dev/null
}

step "Tools"
for tool in docker kind kubectl helm jq curl openssl; do
    command -v "$tool" >/dev/null || { echo "$tool not found. Run this in \`devbox shell\` (Docker has to be installed separately)."; exit 1; }
done
docker info >/dev/null 2>&1 || { echo "Docker isn't running."; exit 1; }

step "KAOP"
ask AGENTOPS_API_KEY "KAOP API key (input hidden)" \
"Sign up for KAOP at https://komodor.com/free-trial. In the KAOP console, open
Settings -> API keys and create a key. It acts as you." secret
ME=$(api GET /auth/me)
KAOP_ACCOUNT=$(jq --raw-output .identity.account.slug <<<"$ME")
PRINCIPAL_ID=$(jq --raw-output .identity.principal.id <<<"$ME")
echo "Account $KAOP_ACCOUNT, signed in as $(jq --raw-output .identity.user.email <<<"$ME")."
ask ANTHROPIC_API_KEY "Anthropic API key for dot-ai (input hidden)" \
"dot-ai, the agent imported into KAOP at the end, calls Anthropic with its own key.
Create one at https://console.anthropic.com/settings/keys." secret

step "Cluster"
if kind get clusters | grep --quiet --line-regexp kaop; then
    echo "kind cluster kaop exists."
else
    kind create cluster --name kaop --kubeconfig "$KUBECONFIG"
fi
kubectl create namespace kaop --dry-run=client --output yaml | kubectl apply --filename - >/dev/null

step "Claude Code"
mkdir -p "$RUNS/claude-code" "$RUNS/claude-code-kaop"
MCP_URL="$KAOP/internal/mcp?account=$KAOP_ACCOUNT"
if command -v claude >/dev/null; then
    # Only in claude-code-kaop: `claude mcp add` applies to the directory it runs in.
    (cd "$RUNS/claude-code-kaop" && { claude mcp get agentops >/dev/null 2>&1 \
        || claude mcp add --transport http agentops "$MCP_URL" >/dev/null; })
    # A developer with KAOP has no cluster access of their own. On a laptop that runs the
    # cluster (kind), a missing kubeconfig isn't enough: Claude Code can mint one with
    # `kind get kubeconfig`. These rules stand in for a laptop that isn't the cluster's host.
    mkdir -p "$RUNS/claude-code-kaop/.claude"
    cat > "$RUNS/claude-code-kaop/.claude/settings.json" <<'EOF'
{
  "permissions": {
    "deny": [
      "Bash(kubectl:*)",
      "Bash(kind:*)",
      "Bash(docker:*)",
      "Bash(helm:*)",
      "Read(~/.kube/**)",
      "Read(//**/kubeconfig.yaml)"
    ]
  }
}
EOF
    echo "KAOP is added to Claude Code in $RUNS/claude-code-kaop, with no cluster access of its own."
    pause "If you haven't signed in to KAOP from Claude Code before: in another terminal, cd $RUNS/claude-code-kaop, run claude, type /mcp, select agentops and sign in."
else
    echo "Claude Code not found. Add this remote MCP server (HTTP, OAuth) to your agent: $MCP_URL"
fi

step "Kubernetes RCA (read-only, from KAOP's catalog)"
worker_token kubernetes-rca-kaop kubernetes-rca-token \
    '{"agentId": "kubernetes-rca-kaop", "displayName": "Kubernetes RCA (kaop)", "clusterName": "kaop", "credentialRef": "LLM_PROXY_TOKEN"}'
install kubernetes-rca helm/kubernetes-rca.yaml
echo "Installed."

step "Shop Remediator (can change the shop)"
# Komodor's base image has no kubectl, so the remediator image adds it.
docker build --quiet --tag "$REMEDIATOR_IMAGE" remediator >/dev/null
kind load docker-image "$REMEDIATOR_IMAGE" --name kaop >/dev/null
worker_token shop-remediator shop-remediator-token
kubectl apply --filename k8s/remediator-rbac.yaml >/dev/null
install shop-remediator helm/shop-remediator.yaml
REMEDIATOR_ID=$(agent_id shop-remediator)
echo "Installed."

step "dot-ai (an agent brought into KAOP)"
# dot-ai's REST token: kept across re-runs, shared with the KAOP worker that calls it.
kubectl create namespace dot-ai --dry-run=client --output yaml | kubectl apply --filename - >/dev/null
DOT_AI_TOKEN=$(kubectl --namespace dot-ai get secret dot-ai-secrets --output jsonpath='{.data.auth-token}' 2>/dev/null | base64 --decode || true)
DOT_AI_TOKEN=${DOT_AI_TOKEN:-$(openssl rand -hex 24)}
kubectl --namespace dot-ai create secret generic dot-ai-secrets \
    --from-literal anthropic-api-key="$ANTHROPIC_API_KEY" --from-literal auth-token="$DOT_AI_TOKEN" \
    --dry-run=client --output yaml | kubectl apply --filename - >/dev/null
kubectl --namespace kaop create secret generic dot-ai-client --from-literal auth-token="$DOT_AI_TOKEN" \
    --dry-run=client --output yaml | kubectl apply --filename - >/dev/null
helm upgrade --install dot-ai oci://ghcr.io/vfarcic/dot-ai/charts/dot-ai --version 1.23.1 \
    --namespace dot-ai --values helm/dot-ai.yaml --wait --timeout 10m >/dev/null
kubectl --namespace dot-ai rollout restart deployment >/dev/null
docker build --quiet --tag "$DOT_AI_WORKER_IMAGE" dotai-worker >/dev/null
kind load docker-image "$DOT_AI_WORKER_IMAGE" --name kaop >/dev/null
worker_token dot-ai dot-ai-worker-token
install dot-ai-worker helm/dot-ai-worker.yaml
DOT_AI_ID=$(agent_id dot-ai)
echo "Installed."

step "Slack"
until api GET /api/v1/integrations/connections | jq --exit-status '.[] | select(.provider == "slack" and .status == "active")' >/dev/null; do
    pause "In the KAOP console, open Settings -> Integrations -> Slack and connect ONE workspace."
done
ask SLACK_CHANNEL_NAME "Slack channel name, without #" \
"Pick a channel in that workspace for approval requests and run reports, and add the
KAOP app to it (in Slack: the channel's details -> Integrations -> Add apps)."
SLACK_CHANNEL_ID=$(api GET "/api/v1/integrations/slack/channels/resolve?name=$SLACK_CHANNEL_NAME" | jq --raw-output .id)
until api GET "/api/v1/integrations/slack/channels/$SLACK_CHANNEL_ID/bot-access" | jq --exit-status .is_member >/dev/null; do
    pause "KAOP's app isn't in #$SLACK_CHANNEL_NAME yet. Add it (the channel's details -> Integrations -> Add apps)."
done
# Approval requests and finished runs go to the channel.
SINK_ID=$(api GET /api/v1/notification-sinks | jq --raw-output --arg name "$SINK_NAME" '.[] | select(.name == $name) | .id' | head -1)
if [ -z "$SINK_ID" ]; then
    SINK_ID=$(jq --arg name "$SINK_NAME" --arg id "$SLACK_CHANNEL_ID" --arg channel "$SLACK_CHANNEL_NAME" \
        '.name = $name | .channel_ids = [$id] | .channel_names = [$channel]' kaop/slack-sink.json \
        | api POST /api/v1/notification-sinks /dev/stdin | jq --raw-output .id)
fi
if ! api GET "/api/v1/notification-sinks/$SINK_ID/subscriptions" \
    | jq --exit-status --arg id "$REMEDIATOR_ID" '.[] | select(.target_id == $id)' >/dev/null; then
    jq --null-input --arg id "$REMEDIATOR_ID" '{target_type: "agent", target_id: $id}' \
        | api POST "/api/v1/notification-sinks/$SINK_ID/subscriptions" /dev/stdin >/dev/null
fi
# Mentioning KAOP's bot in the channel starts the Shop Remediator.
CHANNEL_ID=$(api GET /api/v1/channels | jq --raw-output '.[] | select(.provider == "slack" and .status == "active") | .id' | head -1)
if ! api GET "/api/v1/channels/$CHANNEL_ID/routes" \
    | jq --exit-status --arg id "$REMEDIATOR_ID" --arg channel "$SLACK_CHANNEL_NAME" \
        '.[] | select(.target_id == $id and .match_json.channel_names == [$channel])' >/dev/null; then
    jq --arg id "$REMEDIATOR_ID" --arg channel "$SLACK_CHANNEL_NAME" \
        '.target_id = $id | .match = {channel_names: [$channel]}' kaop/slack-route.json \
        | api POST "/api/v1/channels/$CHANNEL_ID/routes" /dev/stdin >/dev/null
fi
api POST "/api/v1/notification-sinks/$SINK_ID/test-send" >/dev/null
echo "Sent a test message to #$SLACK_CHANNEL_NAME."

step "Approval rules"
# Shop Remediator: kubectl commands that change something wait up to 15 minutes for you in Slack.
permission "$REMEDIATOR_ID" kaop/shop-remediator-permissions.json
# dot-ai: its whole plan waits for you before it executes.
permission "$DOT_AI_ID" kaop/dot-ai-permissions.json
echo "Both agents ask before they change anything."

step "Schedule (disabled until the demo enables it)"
if [ -z "$(api GET /api/v1/schedules | jq --raw-output --arg name "$SCHEDULE_NAME" '.[] | select(.name == $name) | .schedule_id')" ]; then
    jq --arg id "$REMEDIATOR_ID" --arg name "$SCHEDULE_NAME" '.agent_id = $id | .name = $name' kaop/schedule.json \
        | api POST /api/v1/schedules /dev/stdin >/dev/null
fi
echo "Every five minutes, the Shop Remediator checks checkouts and fixes what it finds."

step "The shop, and the incident"
./incident.sh

step "Ready"
echo "Claude Code on its own:  cd $RUNS/claude-code && claude"
echo "Claude Code with KAOP:   cd $RUNS/claude-code-kaop && export KUBECONFIG=\$PWD/kubeconfig.yaml && claude   (no such file: no cluster access)"
echo "Recreate the incident:   ./incident.sh"
