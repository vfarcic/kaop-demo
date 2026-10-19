# Incident report: intermittent checkout failures in `shop`

**Date:** 2026-10-19 · **Cluster:** `kind-kaop` · **Namespace:** `shop`
**Status:** Fixed (mitigated), verified

## Summary

Roughly 1 in 3 requests to `http://storefront/checkout` returned **HTTP 500**. A canary Deployment, `orders-fastpath`, had been deployed with the pod label `app=orders`. The `orders` Service selects pods by `app=orders` alone, so it added the canary pod to its endpoints next to the two stable `orders` pods. The canary runs with `-status-code=500`, so every request routed to it failed. nginx in `storefront` proxied those 500s back to the customer.

**Fix:** I scaled `orders-fastpath` to 0 replicas. The `orders` Service now routes only to the two healthy pods, and checkouts return 200 every time.

## What failed

- `GET /checkout` on `storefront` → nginx `proxy_pass http://orders:8080` → **500 "order accepted"** from the canary pod.
- About 1/3 of requests failed, matching 1 bad endpoint out of 3.
- Requests never failed at the network level. The upstream answered quickly (~5 µs) but with status 500.

## Root cause

```
Service orders            selector: app=orders
Deployment orders         pod labels: app=orders                 (2 pods, 200 OK)
Deployment orders-fastpath pod labels: app=orders, track=fastpath (1 pod, -status-code=500)
```

The `orders-fastpath` Deployment has the annotations *"Canary of the new orders fast path. Not wired into the storefront yet."* and `owner: payments-team`. The annotation says it is not wired in, but the shared `app=orders` label wired it into production traffic automatically. Kubernetes Service selectors match any pod that has the listed labels. The extra `track=fastpath` label does not exclude the pod.

## Evidence

1. **Orders EndpointSlice before the fix** contained 3 IPs: `10.244.0.89`, `10.244.0.90` (orders), and **`10.244.0.95` (orders-fastpath)**.
2. **Canary pod args:** `-listen=:8080 -text=order accepted -status-code=500`.
3. **Canary pod logs** show it serving real storefront traffic with 500s:
   ```
   18:57:11 orders:8080 10.244.0.96:46638 "GET /checkout HTTP/1.1" 500 15 "curl/8.23.0"
   18:57:19 orders:8080 10.244.0.96:60364 "GET /checkout HTTP/1.1" 500 15 "curl/8.23.0"
   ```
   (`10.244.0.96` is a storefront pod.)
4. **Synthetic `shopper` client results per minute (UTC):**

   | Minute | 200 | 500 |
   |---|---|---|
   | 18:51 | 12 | 0 (plus one `000` at startup, before storefront was ready) |
   | 18:52 | 30 | 0 |
   | 18:53 | 30 | 0 |
   | 18:54 | 27 | 3 (first 500 at **18:54:40**) |
   | 18:55 | 17 | 13 |
   | 18:56 | 22 | 8 |
   | 18:57 | 7 | 5 (last 500 at **18:57:21**) |

   The first 500 came 6 seconds after the canary was created at 18:54:34. Before that, the system ran for 3 minutes with zero failures.
5. **Storefront nginx access logs** showed 200s and 500s mixed together for the same `/checkout` path. This rules out a routing or config problem inside nginx.

### Things ruled out

- **`storefront` ConfigMap change and rollout restart (18:55:34).** This happened *after* the failures began, and the failures continued at the same rate afterwards. The current config (`proxy_pass http://orders:8080`) is correct. The restart was most likely a mitigation attempt that didn't help.
- **`newsletter` CrashLoopBackOff.** This is unrelated to checkout. The container tries to reach `mail.internal:25`, then deliberately runs `exit 1`. It is not in the checkout path. It has been crashing since creation (18:51:33), while checkouts were healthy until 18:54:40. It should be fixed separately (SMTP relay is unreachable and/or the script always exits 1).
- **NetworkPolicies / DNS.** There are no NetworkPolicies in the cluster, and no timeouts (`000`) occurred after startup.

## Timeline (UTC, 2026-10-19)

| Time | Event |
|---|---|
| 18:51:33 | `orders`, `storefront`, `shopper`, `newsletter` deployed. `newsletter` starts crash-looping (unrelated). |
| 18:51:35 | Checkouts healthy (200). |
| 18:54:34 | `orders-fastpath` canary created (payments-team) with label `app=orders` and `-status-code=500`. It joins the `orders` Service endpoints. |
| 18:54:40 | First checkout 500. About 1/3 of checkouts fail from here on. |
| 18:55:34 | `storefront` ConfigMap re-applied and `storefront` rollout restarted. No effect on the failure rate. |
| 18:57:21 | Last observed 500. |
| 18:57:31 | **Fix applied:** `kubectl scale deploy/orders-fastpath -n shop --replicas=0`. |
| 18:57:31–18:58:40 | Verification: 260 manual checkouts plus 34 `shopper` checkouts, all 200. |

## Fix applied

```bash
kubectl scale deploy/orders-fastpath -n shop --replicas=0
```

I scaled the canary down instead of deleting it. This keeps the payments team's Deployment and its spec intact, and it is easy to reverse. After the change, the `orders` EndpointSlice contains only `10.244.0.89` and `10.244.0.90`.

## Verification

- `orders` EndpointSlice after the fix: `10.244.0.90,10.244.0.89` (the canary IP is gone).
- 60 back-to-back `curl http://storefront/checkout` from inside the `shopper` pod: **60 × 200**.
- 200 more requests spread over ~1 minute: **200 × 200**.
- The continuous `shopper` client since 18:57:32: **34 × 200, 0 × 500**.

## Follow-ups / permanent fix (for the payments team)

Scaling to 0 is a mitigation. Before the canary is scaled up again, it must not match the production Service selector:

1. **Give the canary a distinct `app` label** (e.g. `app: orders-fastpath`). The Deployment selector is immutable, so this means deleting and re-creating `orders-fastpath`. Or:
2. **Make the stable path explicit:** add `track: stable` to the `orders` pod template, and change the `orders` Service selector to `app=orders, track=stable`. Canaries then only receive traffic when deliberately wired in.
3. Fix the canary itself. `-status-code=500` makes it fail every request, so it should not get real traffic.
4. Consider a guardrail, such as a policy or CI check, that flags new workloads whose pod labels match an existing Service selector in the same namespace.
5. Separately, fix `newsletter` (SMTP relay `mail.internal:25` unreachable; script always `exit 1`).
