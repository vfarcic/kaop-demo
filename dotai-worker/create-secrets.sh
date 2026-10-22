#!/usr/bin/env bash
# Creates the dot-ai Secret (Anthropic key, REST bearer token) and gives the KAOP worker the same token.
# Run under `vals exec -f .env.vals.yaml`; no value is printed.
set -euo pipefail
TOKEN=$(openssl rand -hex 24)
kubectl create namespace dot-ai --dry-run=client --output yaml | kubectl apply --filename -
kubectl --namespace dot-ai create secret generic dot-ai-secrets \
    --from-literal anthropic-api-key="$ANTHROPIC_API_KEY" \
    --from-literal auth-token="$TOKEN" \
    --dry-run=client --output yaml | kubectl apply --filename -
kubectl --namespace kaop create secret generic dot-ai-client \
    --from-literal auth-token="$TOKEN" \
    --dry-run=client --output yaml | kubectl apply --filename -
