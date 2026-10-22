#!/usr/bin/env bash
# Usage: run.sh <claude-code|claude-code-kaop|claude-code-kaop-only>
# Runs one condition headless in its own clean directory and saves the full stream.
set -euo pipefail
R=/Users/viktorfarcic/code/kaop-runs
C="$1"
cd "$R/$C"
cp /Users/viktorfarcic/code/kaop-demo/kubeconfig.yaml ./kubeconfig.yaml
rm -f report.md run.jsonl
export KUBECONFIG="$R/$C/kubeconfig.yaml"
export PATH="/Users/viktorfarcic/code/kaop-demo/.devbox/nix/profile/default/bin:$PATH"
TASK="Customers report that some checkouts fail in the shop namespace. Do a full analysis: what is failing, why, and how to fix it. Then apply the fix and verify that checkouts work. Write your report to report.md: what failed, root cause, evidence, timeline, the fix you applied, and how you verified it."
KAOP_NOTE="You have access to Komodor's Agentic Operations Platform (KAOP) over MCP; use it where it helps."
BASH_TOOLS=("Bash(kubectl:*)" "Bash(grep:*)" "Bash(awk:*)" "Bash(sort:*)" "Bash(uniq:*)"
  "Bash(head:*)" "Bash(tail:*)" "Bash(wc:*)" "Bash(jq:*)" "Bash(sleep:*)" "Bash(date:*)")
DENY=("Read" "Glob" "Grep" "WebFetch" "WebSearch" "Task")
case "$C" in
  claude-code)
    MCP="$R/no-mcp.json"; PROMPT="$TASK"; ALLOW=("${BASH_TOOLS[@]}" "Write") ;;
  claude-code-kaop)
    MCP="$R/agentops-mcp.json"; PROMPT="$TASK

$KAOP_NOTE"; ALLOW=("${BASH_TOOLS[@]}" "Write" "mcp__agentops") ;;
  claude-code-kaop-only)
    # No cluster access at all: no kubeconfig, no Bash. KAOP is the only way in.
    rm -f ./kubeconfig.yaml; unset KUBECONFIG
    MCP="$R/agentops-mcp.json"; PROMPT="$TASK

$KAOP_NOTE"; ALLOW=("Write" "mcp__agentops"); DENY+=("Bash") ;;
  *) echo "unknown condition $C"; exit 1 ;;
esac
claude -p "$PROMPT" \
  --model "${MODEL:-opus}" \
  --mcp-config "$MCP" --strict-mcp-config \
  --output-format stream-json --verbose \
  --allowedTools "${ALLOW[@]}" \
  --disallowedTools "${DENY[@]}" \
  > run.jsonl 2> run.err
tail -1 run.jsonl | jq '{duration_ms, num_turns, total_cost_usd, is_error}'
