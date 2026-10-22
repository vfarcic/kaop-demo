#!/usr/bin/env bash
# Recreates the shop namespace and the incident with the manuscript's Setup steps.
set -euo pipefail
cd /Users/viktorfarcic/code/kaop-demo
export KUBECONFIG=$PWD/kubeconfig.yaml PATH=$PWD/.devbox/nix/profile/default/bin:$PATH
kubectl delete namespace shop --ignore-not-found --wait=true >/dev/null
kubectl apply --filename k8s/app.yaml >/dev/null
kubectl --namespace shop rollout status deployment/storefront >/dev/null
# The remediator's write Role lives in shop, so it has to come back with the namespace.
if [ "${WITH_REMEDIATOR:-}" = "true" ]; then kubectl apply --filename k8s/remediator-rbac.yaml >/dev/null; fi
sleep 180
echo "canary $(date -u +%T)"
kubectl apply --filename k8s/incident/orders-fastpath.yaml >/dev/null
kubectl --namespace shop rollout status deployment/orders-fastpath >/dev/null
sleep 60
echo "decoy  $(date -u +%T)"
kubectl apply --filename k8s/incident/storefront-config-change.yaml >/dev/null
kubectl --namespace shop rollout restart deployment/storefront >/dev/null
kubectl --namespace shop rollout status deployment/storefront >/dev/null
# The remediator's write Role lives in shop, so it has to come back with the namespace.
if [ "${WITH_REMEDIATOR:-}" = "true" ]; then kubectl apply --filename k8s/remediator-rbac.yaml >/dev/null; fi
sleep 90
echo "status $(kubectl -n shop logs deployment/shopper | awk '{print $2}' | sort | uniq -c | tr '\n' ' ')"
