# Checkout Failure — Root Cause Analysis & Fix

## Summary

Customers checking out via the storefront intermittently received **HTTP 500** errors.
Root cause: a canary deployment (`orders-fastpath`) that was explicitly documented as
"not wired into the storefront yet" accidentally shared the `app=orders` label with the
production `orders` Deployment. The `orders` Service selects pods on `app=orders` only,
so Kubernetes silently added the canary pod — which was hardcoded to always return
`-status-code=500` — to the `orders` Service's load-balancing pool. Roughly 1 in 3
checkout requests were routed to the broken canary pod and failed.

## What was failing

- **Service**: `shop` namespace, customer checkout flow (`storefront` → `orders`).
- **Symptom**: intermittent `500` responses observed both by the synthetic `shopper`
  client and by a direct reproduction against the `storefront` Service, interleaved
  with successful `200` responses (never 100% down — classic "some checkouts fail").

## Root cause

- The `orders` Service selector is `app: orders` (`kubectl get svc orders -o yaml`).
- A new Deployment, `orders-fastpath`, was created by the payments team as a canary:
  ```
  annotations:
    description: "Canary of the new orders fast path. Not wired into the storefront yet."
    owner: payments-team
  spec:
    selector:
      matchLabels: {app: orders, track: fastpath}
    template:
      metadata:
        labels: {app: orders, track: fastpath}
      containers:
      - image: hashicorp/http-echo:1.0.0
        args: ["-listen=:8080", "-text=order accepted", "-status-code=500"]
  ```
- Because the canary's pod template still carried `app: orders` (to satisfy its own
  Deployment selector, which also required `track: fastpath`), its pod also matched the
  **`orders` Service's** selector (`app: orders`), which has no `track` constraint.
- Kubernetes therefore added the canary pod's IP to the `orders` Service's endpoint list
  alongside the two real `orders` pods — even though nothing in the storefront's nginx
  config (`proxy_pass http://orders:8080;`) or anyone's intent referenced the canary.
  The canary was built to always return HTTP 500, so it never served a real order — it
  just siphoned off ~1/3 of checkout traffic and failed it.
- This is a label-selector overlap bug, not an application bug: the canary's isolation
  depended on nobody else's Service selector being broad enough to catch it, and the
  `orders` Service selector was broad enough.

## Evidence

- `kubectl get endpoints orders -n shop` (before fix) showed **3** endpoints:
  `10.244.0.30:8080, 10.244.0.31:8080` (real `orders` pods) and `10.244.0.36:8080`
  (the `orders-fastpath` pod) — confirming the canary was live in the Service pool.
- `kubectl get deployment orders-fastpath -o yaml` showed `args: [..., "-status-code=500"]`
  and the annotation `"Canary of the new orders fast path. Not wired into the storefront yet."`
  — confirming the pod always returns 500 and was never meant to take traffic.
- `shopper` client logs (continuous curl loop against the storefront) showed clean `200`s
  before the canary existed, then a mix of `200`/`500` starting immediately after the
  canary pod came up:
  ```
  17:09:58    200   <- last clean response before canary rollout
  17:10:02    500   <- first failure, 4s after orders-fastpath pod became Ready
  17:10:04    200
  17:10:08    500
  17:10:12    500
  ... (intermittent 500s continue for ~3 minutes)
  ```
- A direct 20-request curl loop against the `storefront` Service during the incident
  window also reproduced intermittent 500s, ruling out `shopper`-side flakiness.
- `newsletter-7f6d6d65c9-hcxrm` was separately found in `CrashLoopBackOff`
  (`smtp relay unreachable, giving up`) — this is an unrelated, pre-existing issue in a
  different deployment (newsletter signup, not checkout) and was left untouched; noting
  it here for completeness since it also showed up in `kubectl get pods -n shop`.

## Timeline (UTC, 2026-10-19)

| Time | Event |
|---|---|
| 17:06:57 | `shop` namespace workloads created: `orders` (2 replicas), `storefront`, `shopper` synthetic traffic generator. Checkouts healthy. |
| 17:09:58 | `orders-fastpath` canary Deployment created by payments-team with label `app=orders` and `-status-code=500`. Pod becomes Ready almost immediately. |
| 17:10:02 | First `500` observed in `shopper` logs — canary pod added to `orders` Service endpoints and starts receiving ~1/3 of checkout traffic. |
| 17:10:02–17:12:58 | Intermittent checkout failures continue (observed error rate ~13–33%, consistent with 1 bad endpoint out of 2–3). |
| 17:13:18 | Investigation started: confirmed `orders` Service endpoints included the canary pod IP; confirmed canary's `-status-code=500` arg and "not wired in yet" annotation. |
| 17:13:3x | Fix applied: `orders-fastpath` Deployment deleted and recreated with `app: orders-fastpath` (instead of `app: orders`), keeping `track: fastpath`, so it no longer matches the `orders` Service selector. |
| 17:13:42 | `kubectl get endpoints orders` shows only the 2 real `orders` pod IPs; canary pod no longer receiving checkout traffic. |
| 17:13:54–17:14:52 | `shopper` logs show continuous `200` responses, zero errors. |
| 17:14:xx | Direct 20-request verification curl against `storefront` Service: 20/20 `200`. |

## Fix applied

Deleted and recreated the `orders-fastpath` Deployment with a pod label that no longer
collides with the `orders` Service selector:

- Before: pod labels `app: orders, track: fastpath` → matched `orders` Service (`app: orders`).
- After: pod labels `app: orders-fastpath, track: fastpath` → no longer matched.

No changes were made to the production `orders` Deployment, the `orders` Service, or the
`storefront` config — the canary is now fully isolated, as the team's own annotation said
it was intended to be, and remains available (1 replica, still returning 500 by design)
for the payments team to wire up deliberately later via its own Service when it's ready,
rather than being accidentally exposed through the shared `orders` Service.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: orders-fastpath
  namespace: shop
  annotations:
    description: "Canary of the new orders fast path. Not wired into the storefront yet."
    owner: payments-team
spec:
  replicas: 1
  selector:
    matchLabels: {app: orders-fastpath, track: fastpath}
  template:
    metadata:
      labels: {app: orders-fastpath, track: fastpath}
    spec:
      containers:
      - name: orders
        image: hashicorp/http-echo:1.0.0
        args: ["-listen=:8080", "-text=order accepted", "-status-code=500"]
        ports: [{containerPort: 8080}]
```

## Verification

1. `kubectl get endpoints orders -n shop` — now lists only the two healthy `orders` pod
   IPs (`10.244.0.30:8080`, `10.244.0.31:8080`); the canary IP is gone.
2. `kubectl logs -n shop deployment/shopper --since=60s` — ~30 consecutive requests
   post-fix, all `200`, zero `500`s (previously interleaved with failures every few
   requests).
3. Direct reproduction: ran a throwaway pod (`curlimages/curl`) issuing 20 requests
   straight at the `storefront` Service — **20/20 returned `200`**.
4. `orders-fastpath` pod confirmed still `Running` and healthy on its own, but with
   labels `app=orders-fastpath,track=fastpath` — verified via
   `kubectl get pods -l track=fastpath --show-labels` — confirming it's isolated from
   the `orders` Service without being torn down.

## Recommendation (not applied, out of scope for this fix)

To prevent this class of incident recurring, consider tightening the `orders` Service
selector to something more specific than `app: orders` alone (e.g. require a
`track: stable` label present on production `orders` pods), so any future canary that
reuses the `app` label by convention can't be swept into production traffic by accident.
