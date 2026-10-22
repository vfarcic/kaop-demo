# Incident Report: Intermittent checkout failures in `shop` namespace

**Date:** 2026-10-19 · **Cluster:** `kind-kaop` · **Status:** Resolved

## Summary

About 1 in 3 checkouts (`GET http://storefront/checkout`) returned **HTTP 500**. The `orders-fastpath` canary Deployment (owner: payments-team) was created with the pod label `app=orders`. That label matches the selector of the production `orders` Service, so the Service started load-balancing real checkout traffic to the canary. The canary is hard-wired to return 500 (`-status-code=500`).

## What failed

- Request path: `shopper` → `storefront` Service (nginx, `proxy_pass http://orders:8080`) → `orders` Service → orders pods.
- The `orders` Service had **3 endpoints** instead of 2:
  - `10.244.0.51`, `10.244.0.52`: `orders` Deployment, returned 200
  - `10.244.0.57`: `orders-fastpath` canary, returned **500**
- The result was about a 1/3 failure rate. All pods showed Ready/Running, so nothing looked unhealthy from Kubernetes' point of view.

## Root cause

`orders-fastpath` uses the pod labels `{app: orders, track: fastpath}`. The `orders` Service selector was just `{app: orders}`. A Service selector matches every pod that has *at least* the listed labels, so the canary pods became Service endpoints. Its annotation reads *"Canary of the new orders fast path. Not wired into the storefront yet."* The authors meant to keep it out of production traffic, but the shared label wired it in anyway. The canary container runs `http-echo ... -status-code=500`, so every request it received failed.

## Evidence

1. **EndpointSlice** `orders-8t2p7` before the fix: `10.244.0.51,10.244.0.52,10.244.0.57`. `.57` is `orders-fastpath-8476ddbc8b-k8ddg`.
2. **Direct probe of each endpoint** from the shopper pod: `.51 → 200`, `.52 → 200`, `.57 → 500`.
3. **Canary logs** show it serving real `/checkout` requests that came from the storefront pods (`10.244.0.58/59`) and answering with 500.
4. **Storefront nginx access logs** show a mix of 200 and 500 on `/checkout`.
5. **Shopper (synthetic customer) logs:**
   - 18:14:58–18:17:59: 90 × 200, 0 × 500 (ignoring one `000` at pod startup, before storefront was ready)
   - 18:18:00–18:21:08: 67 × 200, **27 × 500** (~29% failures)
6. **Timing:** `orders-fastpath` was created at 18:17:59Z and the first 500 appeared at 18:18:05Z.

### Ruled out (red herrings)

- **Storefront ConfigMap change and rollout restart at 18:18:59Z** (added `proxy_connect_timeout 2s` and the `X-Request-ID` header). Failures started about 1 minute *before* this change, and the new config proxies correctly. Not the cause.
- **`newsletter` CrashLoopBackOff.** It can't reach the SMTP relay `mail.internal:25` and exits 1 by design. It isn't in the checkout path. This is a separate issue for whoever owns newsletter, but it isn't related to this incident.
- No NetworkPolicies or Ingresses exist in the namespace.

## Timeline (UTC)

| Time | Event |
|---|---|
| 18:14:58 | `shop` workloads deployed (orders ×2, storefront ×2, shopper, newsletter) |
| 18:15–18:17 | Checkouts 100% successful |
| 18:17:59 | `orders-fastpath` canary created with label `app=orders`; joins `orders` Service endpoints |
| 18:18:05 | First checkout 500 |
| 18:18:59 | Storefront ConfigMap updated and storefront restarted (unrelated) |
| 18:18–18:21 | ~29% of checkouts fail with 500 |
| 18:21:02 | Root cause confirmed by probing each orders endpoint directly |
| 18:21:08 | Fix applied: orders pods relabelled, Service selector narrowed |
| 18:21:09+ | Checkouts 100% successful |

## Fix applied

I isolated the stable orders pods with an explicit track label, so the canary keeps running for payments-team but gets no production traffic:

```bash
# 1. Add track=stable to the orders pod template (rolling update, no downtime)
kubectl patch deploy orders -n shop --type merge \
  -p '{"spec":{"template":{"metadata":{"labels":{"app":"orders","track":"stable"}}}}}'
kubectl rollout status deploy/orders -n shop

# 2. Narrow the Service selector so only stable pods are endpoints
kubectl patch svc orders -n shop --type merge \
  -p '{"spec":{"selector":{"app":"orders","track":"stable"}}}'
```

The order of these steps matters. The pods were relabelled first, then the selector was narrowed, so the Service never had zero endpoints. The Deployment's own selector (`app=orders`) is immutable and was left unchanged.

## Verification

- `orders` EndpointSlice now lists only `10.244.0.60,10.244.0.61` (both `track=stable`). The canary `10.244.0.57` is excluded.
- 100 consecutive `GET http://storefront/checkout` requests from the shopper pod: **100 × 200, 0 × 500**.
- Ongoing shopper traffic after 18:21:09: **23 × 200, 0 × 500**.
- The `orders-fastpath` canary is still running, untouched, and reachable only directly.

## Follow-ups / recommendations

1. **Persist the fix in source manifests.** The changes were made with `kubectl patch`. The `orders` Deployment and Service manifests (last-applied config) still have the old labels and selector, so a re-apply from the old manifests would bring the outage back.
2. **payments-team:** give canaries a distinct `app` label (e.g. `app: orders-fastpath`). If the canary is meant to receive traffic, route it on purpose through a weighted mechanism (Gateway API / mesh). Don't let it ride a shared label.
3. **Detection:** alert on the storefront/orders 5xx rate. Pods were all Ready, so health-based monitoring missed this. Consider readiness probes on `orders` that exercise a real endpoint.
4. **Separate issue:** the `newsletter` deployment is in CrashLoopBackOff because `mail.internal:25` is unreachable. Its owner should look at this. It doesn't affect checkout.
