#!/usr/bin/env bash
# Recreates the shop app and breaks it. Run it from the repo root, in `devbox shell`.
# Used by setup.sh, and between sections of the demo to start from the same incident.
set -euo pipefail
cd "$(dirname "$0")"
export KUBECONFIG="${KUBECONFIG:-$PWD/kubeconfig.yaml}"

# The namespace stays: the agents' Roles live in it. Its workloads, config and events go,
# so nothing from an earlier run (an applied fix, its events) is left for an agent to find.
echo "Recreating the shop..."
kubectl apply --filename k8s/app.yaml >/dev/null
kubectl --namespace shop delete deployment,job,pod,service,configmap,event --all --wait=true >/dev/null
kubectl apply --filename k8s/app.yaml >/dev/null
kubectl --namespace shop rollout status deployment/storefront >/dev/null

# A few minutes of healthy history, so the agents can see when it broke.
echo "Letting the shop run healthy for three minutes..."
sleep 180

# Two changes, a minute apart, in this order on purpose. Don't read the files
# if you want to diagnose it yourself.
echo "Breaking it..."
kubectl apply --filename k8s/incident/orders-fastpath.yaml >/dev/null
kubectl --namespace shop rollout status deployment/orders-fastpath >/dev/null
sleep 60
kubectl apply --filename k8s/incident/storefront-config-change.yaml >/dev/null
kubectl --namespace shop rollout restart deployment/storefront >/dev/null
kubectl --namespace shop rollout status deployment/storefront >/dev/null

echo "Done. Within a minute or two, roughly one checkout in three fails."
