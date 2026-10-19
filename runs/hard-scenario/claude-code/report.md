# Shop Checkout Failure — Incident Report

## Summary

Checkouts in the `shop` namespace were intermittently failing with HTTP 500
errors (~1 in 3 requests). Root cause: a canary deployment (`orders-fastpath`)
that was explicitly documented as "not wired into the storefront yet" was
accidentally receiving live production traffic because its pods carried the
same `app: orders` label as the production `orders` pods, which is exactly
the label the `orders` Service uses to select its backends. The canary always
responds with HTTP 500. Fix: scoped the `orders` Service selector to only the
stable track, so the canary is excluded from serving live traffic while
remaining deployed for the owning team (payments-team) to test.

## What was failing

- The `storefront` service proxies all traffic on `/` (including `/checkout`)
  to `http://orders:8080` (see the `storefront` ConfigMap's nginx config).
- A synthetic load-generator pod, `shopper`, continuously calls
  `http://storefront/checkout` every 2 seconds and logs the HTTP status code.
  Its logs showed a steady mix of `200` and `500` responses, e.g.:

  ```
  17:01:21 200
  17:01:23 200
  17:01:25 200
  17:01:27 500
  17:01:29 500
  17:01:31 500
  17:01:33 200
  ...
  ```

  Roughly 1 in 3 requests failed, consistent with 1 of the 3 pods behind the
  `orders` Service always returning an error.

## Root cause

- `kubectl get endpoints orders -n shop` showed **3** backend pods for the
  `orders` Service, even though the `orders` Deployment only runs **2**
  replicas:
  - `orders-574f6fc5b9-dn2wv` (production, `hashicorp/http-echo`, `-text="order accepted"`)
  - `orders-574f6fc5b9-fm86d` (production, same as above)
  - `orders-fastpath-8476ddbc8b-pz94n` (canary, `-status-code=500`, always fails)
- The `orders-fastpath` Deployment is annotated:
  ```
  description: Canary of the new orders fast path. Not wired into the storefront yet.
  owner: payments-team
  ```
  i.e., it was intended to be isolated and not receive real traffic.
- However, its pod template labels are `app: orders, track: fastpath`, and
  the `orders` Service selector is only `app: orders` (with no `track`
  qualifier). Kubernetes Service selectors are a simple equality match, so
  any pod with `app: orders` — including the canary — was picked up as a
  valid backend, regardless of the `track` label or the deployment's
  "not wired in yet" intent.
- Direct evidence: calling `http://orders:8080` directly from inside the
  cluster showed the same ~1-in-3 failure rate as `http://storefront/checkout`,
  confirming the failures originate at the `orders` Service layer, not in
  `storefront`/nginx.
- A separate, unrelated issue was also observed: the `newsletter` pod is
  crash-looping because it can't reach `mail.internal:25` (no such host in
  this cluster). This is not on the checkout path (`storefront` only proxies
  to `orders`) and does not affect checkout traffic, so it was left as-is and
  is called out here only for completeness.

## Timeline

- `16:41:33` — `shop` namespace resources created (`storefront`, `orders`,
  `shopper`, `newsletter`), `orders` Service initially has 2 healthy
  endpoints, checkouts succeed.
- `16:44:12` — `orders-fastpath` canary Deployment created by payments-team.
  Its pod joins the `orders` Service's endpoint list (endpoint change trigger
  time matches exactly:
  `endpoints.kubernetes.io/last-change-trigger-time: "2026-10-19T16:44:12Z"`).
  From this point on, ~1/3 of requests to `orders` (and therefore to
  `storefront`/checkout) return HTTP 500.
- `16:44:12` → `17:03:56` — intermittent checkout failures ongoing, as
  recorded continuously in the `shopper` pod's logs.
- `~17:04` — Investigation performed: confirmed `orders` Service endpoints
  included the canary pod; confirmed the canary always returns 500; confirmed
  `storefront` simply proxies to `orders`.
- `17:04` — Fix applied (see below).
- `17:04:18` — last observed `500` in the `shopper` log (in-flight request
  during the rollout/selector update).
- `17:04:20` onward — all checkout requests return `200` (verified
  continuously for 40+ consecutive requests over 40+ seconds, and ongoing in
  the live `shopper` log).

## Fix applied

Rather than modifying the payments-team-owned `orders-fastpath` canary
(which explicitly states it should not be wired into the storefront), the
`orders` Service was scoped to only select the stable track:

1. Added a `track: stable` label to the `orders` Deployment's pod template
   (does not change the Deployment's immutable selector, which remains
   `app: orders`):
   ```
   kubectl patch deployment orders -n shop --type='json' \
     -p='[{"op":"add","path":"/spec/template/metadata/labels/track","value":"stable"}]'
   ```
   This triggered a normal rolling update of the 2 `orders` pods.
2. Updated the `orders` Service selector to require `track: stable` in
   addition to `app: orders`:
   ```
   kubectl patch service orders -n shop --type='json' \
     -p='[{"op":"add","path":"/spec/selector/track","value":"stable"}]'
   ```

Result: `kubectl get endpoints orders -n shop` now shows exactly 2 endpoints
(the stable `orders` pods); the `orders-fastpath` canary pod is excluded. The
canary Deployment itself was not touched and is still running for
payments-team's own testing — it's just no longer in the traffic path.

## Verification

- `kubectl get endpoints orders -n shop` → 2 endpoints (both stable `orders`
  pods), canary pod no longer listed.
- Ran 40 sequential requests from inside the cluster to
  `http://storefront/checkout`: **40/40 returned `200`**.
- The `shopper` pod's continuous synthetic-checkout log shows no `500`
  responses after `17:04:18`, with 20+ consecutive `200`s and counting at
  time of writing.
- `orders-fastpath` pod is still `1/1 Running` (untouched), confirming the
  canary remains available to its owning team without affecting production
  checkout traffic.
