#!/usr/bin/env bash
# Three iterations of each condition on one model, a fresh incident before every run.
set -uo pipefail
R=/Users/viktorfarcic/code/kaop-runs
export MODEL="${MODEL:-opus}"
OUT="$R/results/three-runs"
mkdir -p "$OUT"
for i in 1 2 3; do
  for c in claude-code claude-code-kaop-only; do
    echo "=== $c iteration $i ($(date -u +%T))"
    "$R/rebuild.sh"
    "$R/run.sh" "$c" || echo "run failed"
    D="$OUT/$c/iter-$i"; mkdir -p "$D"
    cp "$R/$c/run.jsonl" "$R/$c/run.err" "$D/" 2>/dev/null
    [ -f "$R/$c/report.md" ] && cp "$R/$c/report.md" "$D/" || echo "no report.md"
    # Snapshot the cluster right after the run, to grade the fix independently.
    KUBECONFIG=/Users/viktorfarcic/code/kaop-demo/kubeconfig.yaml \
      /Users/viktorfarcic/code/kaop-demo/.devbox/nix/profile/default/bin/kubectl -n shop get endpoints orders > "$D/after-endpoints.txt" 2>&1
    sleep 30
    KUBECONFIG=/Users/viktorfarcic/code/kaop-demo/kubeconfig.yaml \
      /Users/viktorfarcic/code/kaop-demo/.devbox/nix/profile/default/bin/kubectl -n shop logs deployment/shopper --since=30s \
      | awk '{print $2}' | sort | uniq -c > "$D/after-30s-statuses.txt" 2>&1
    cat "$D/after-30s-statuses.txt"
  done
done
echo "=== done $(date -u +%T)"
