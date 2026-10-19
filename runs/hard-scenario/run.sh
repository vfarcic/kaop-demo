#!/usr/bin/env bash
# Usage: run.sh <claude-code|claude-code-kaop>
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
if [ "$C" = "claude-code-kaop" ]; then
  MCP="$R/agentops-mcp.json"
  PROMPT="$TASK

You have access to Komodor's Agentic Operations Platform (KAOP) over MCP; use it where it helps."
  EXTRA=(mcp__agentops)
else
  MCP="$R/no-mcp.json"
  PROMPT="$TASK"
  EXTRA=()
fi
claude -p "$PROMPT" \
  --model claude-sonnet-5 \
  --mcp-config "$MCP" --strict-mcp-config \
  --output-format stream-json --verbose \
  --allowedTools "Bash(kubectl:*)" "Bash(grep:*)" "Bash(awk:*)" "Bash(sort:*)" "Bash(uniq:*)" \
    "Bash(head:*)" "Bash(tail:*)" "Bash(wc:*)" "Bash(jq:*)" "Bash(sleep:*)" "Bash(date:*)" \
    "Write" "${EXTRA[@]}" \
  --disallowedTools "Read" "Glob" "Grep" "WebFetch" "WebSearch" "Task" \
  > run.jsonl 2> run.err
tail -1 run.jsonl | jq '{duration_ms, num_turns, total_cost_usd, is_error}'
