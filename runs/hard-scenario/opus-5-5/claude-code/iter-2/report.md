# Incident report: intermittent checkout failures in `shop`

**Date:** 2026-10-19 · **Cluster:** `kind-kaop` · **Namespace:** `shop`
**Status:** Mitigated. Checkouts succeed 100% of the time. A permanent fix is still needed (see "Follow-ups").

## Summary

About **1 in 3** `GET /checkout` requests returned **HTTP 500**. The cause was a new canary deployment, `orders-fastpath`, owned by payments-team. Its pod template has the label `app=orders`, which matches the selector of the production `orders` Service. Kubernetes therefore added the canary pod as a third backend behind `orders`, and the canary always returns 500 (`-status-code=500`). nginx in `storefront` load-balances across the Service, so roughly a third of checkouts went to the canary and failed.

## What failed

- Request path: `shopper` (synthetic customer) → `storefront` Service (nginx, `proxy_pass http://orders:8080`) → `orders` Service → orders pods.
- Shopper results before the fix: 144 × 200, 31 × 500. Every 500 came after 18:36:00Z. Per minute it was about 20 × 200 and 10 × 500, which is exactly 1/3 failing.

## Root cause

| Resource | Pod labels | Behaviour |
|---|---|---|
| `deploy/orders` (2 replicas) | `app=orders` | returns `200 order accepted` |
| `deploy/orders-fastpath` (1 replica) | `app=orders, track=fastpath` | args include `-status-code=500`, so it **always returns 500** |
| `svc/orders` | selector `app=orders` | matches **all 3 pods** |

The canary's annotation says *"Canary of the new orders fast path. Not wired into the storefront yet."* That was the intent. In practice, reusing the `app=orders` label wired it straight into production traffic. Three endpoints with one bad one gives the ~33% failure rate we saw.

## Evidence

- `kubectl get endpoints orders` before the fix: `10.244.0.71, 10.244.0.72, 10.244.0.77`. `.77` is the `orders-fastpath-8476ddbc8b-tz9x8` pod.
- Canary pod log: `"GET /checkout HTTP/1.1" 500 ... 10.244.0.78` (requests proxied from a storefront pod).
- Request counts per pod: the stable pods served 83 and 67 requests; the canary served 32, and every one of those was a 500.
- The 500s start at 18:36:03Z, 4 seconds after `orders-fastpath` was created at 18:35:59Z.

### Ruled out (red herrings)

- **`storefront` rollout at 18:36:59Z** (`kubectl rollout restart` together with a ConfigMap apply). It started a minute *after* the errors began, and the failure rate stayed at about 1/3 before and after it. The current nginx config is correct.
- **`newsletter` in CrashLoopBackOff.** It cannot reach `mail.internal:25` (`smtp relay unreachable, giving up`), and its script always ends with `exit 1`. It has been failing since the namespace was created at 18:32:57Z and has no part in the checkout path. It needs its own ticket.
- The single `000` at 18:32:58Z was the shopper starting before storefront was ready.

## Timeline (UTC)

| Time | Event |
|---|---|
| 18:32:57 | `shop` namespace workloads created. Checkouts return 200. `newsletter` starts crash-looping (unrelated). |
| 18:35:59 | `orders-fastpath` canary created with label `app=orders`. Its pod joins the `orders` Service endpoints. |
| 18:36:03 | First checkout 500. About 33% of checkouts fail from here on. |
| 18:36:59 | `storefront` ConfigMap re-applied and deployment restarted. No change in failure rate. |
| ~18:38 | Investigation identifies the canary in the `orders` endpoints. |
| 18:39:22 | Last observed checkout 500. |
| 18:39:27 | Mitigation: `orders-fastpath` scaled to 0 replicas. |
| 18:40:02 | Verified: 60/60 manual checkouts return 200, and shopper shows only 200s. |

## Fix applied

```sh
kubectl scale deploy/orders-fastpath -n shop --replicas=0
```

This stops the broken canary and removes it from the `orders` Service. It is fully reversible, and the deployment object is kept for payments-team.

I first tried a fix that would have kept the canary running but out of production traffic: add `track: stable` to the `orders` pod template, then change the `orders` Service selector to `app=orders,track=stable`. The environment's permission policy blocked that change, so I used the simpler scale-down instead.

## Verification

- `orders` EndpointSlice now lists only `orders-574f6fc5b9-4wnkk` (10.244.0.71) and `orders-574f6fc5b9-9wmnp` (10.244.0.72).
- `kubectl exec deploy/shopper -- curl http://storefront/checkout` ×60 gave **60 × 200, 0 errors**.
- Shopper loop logs since the fix show 200s only. The last 500 was at 18:39:22, before the scale-down.

## Follow-ups

1. **Permanent isolation of the canary (payments-team):** give `orders-fastpath` a distinct `app` label (for example `app=orders-fastpath`), or narrow `svc/orders` to `app=orders,track=stable` and add `track: stable` to the `orders` pods. Only scale the canary back up after one of these is done.
2. Fix the canary itself: it is hard-coded to return 500 (`-status-code=500`).
3. Add a guardrail, such as a policy or review check, that flags new workloads whose labels match an existing production Service selector.
4. `newsletter`: provide a working SMTP relay (`mail.internal` is not resolvable or reachable), and stop the script from always ending with `exit 1`. This is a separate issue.
