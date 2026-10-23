#!/usr/bin/env bash
# Recreates the dot-agent-deck website and breaks it. Run it from the repo root, in `devbox shell`.
# Used by setup.sh, and between sections of the demo to start from the same incident.
set -euo pipefail
cd "$(dirname "$0")"
# Always the repo's cluster, whatever KUBECONFIG the shell has (the Claude Code with KAOP
# directory points it at a file that doesn't exist).
export KUBECONFIG=$PWD/kubeconfig.yaml

# The namespace stays: the agents' Roles live in it. Its workloads, config and events go,
# so nothing from an earlier run (an applied fix, its events) is left for an agent to find.
echo "Recreating the website..."
kubectl apply --filename k8s/app.yaml >/dev/null
kubectl --namespace dot-agent-deck delete deployment,job,pod,service,configmap,event --all --wait=true >/dev/null
kubectl apply --filename k8s/app.yaml >/dev/null
kubectl --namespace dot-agent-deck rollout status deployment/website >/dev/null

# A few minutes of healthy history, so the agents can see when it broke.
echo "Letting the website run healthy for three minutes..."
sleep 180

# Two changes, a minute apart, in this order on purpose. Don't read the files
# if you want to diagnose it yourself.
echo "Breaking it..."
kubectl apply --filename k8s/incident/website-preview.yaml >/dev/null
kubectl --namespace dot-agent-deck rollout status deployment/website-preview >/dev/null
sleep 60
kubectl apply --filename k8s/incident/website-config-change.yaml >/dev/null
kubectl --namespace dot-agent-deck rollout restart deployment/website >/dev/null
kubectl --namespace dot-agent-deck rollout status deployment/website >/dev/null

echo "Done. Within a minute or two, roughly one request in three to http://dot-agent-deck.127.0.0.1.nip.io fails."
