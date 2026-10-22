#!/usr/bin/env bash
# Usage: continue.sh <run_id> "<follow-up>"
# A fresh, isolated Claude Code (KAOP MCP only, no kubectl) continues an existing KAOP run.
set -euo pipefail
R=/Users/viktorfarcic/code/kaop-runs
cd "$R/claude-code-kaop-continue"
rm -f report.md run.jsonl
PROMPT="KAOP run $1 was started from Slack. Continue that conversation with the same agent, so it keeps its context: $2 Write what you asked and what it answered to report.md."
claude -p "$PROMPT" \
  --model "${MODEL:-claude-opus-5-5}" \
  --mcp-config "$R/agentops-mcp.json" --strict-mcp-config \
  --output-format stream-json --verbose \
  --allowedTools "Write" "mcp__agentops" \
  --disallowedTools "Read" "Glob" "Grep" "WebFetch" "WebSearch" "Task" "Bash" \
  > run.jsonl 2> run.err
tail -1 run.jsonl | jq '{duration_ms, num_turns, total_cost_usd, is_error}'
