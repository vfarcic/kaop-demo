# Incident Report: Intermittent checkout failures in `shop` namespace

**Date:** 2026-10-21
**Status:** Root cause found. The fix is defined, but it is **NOT YET APPLIED**: KAOP requires a human to approve it, and every approval request timed out.
**Tools:** Komodor Agentic Operations Platform (KAOP). The agent "Kubernetes RCA (kaop)" ran the read-only investigation, and the agent "Shop Remediator" ran the remediation attempts.

## 1. What failed

About 1 in 3 `GET /checkout` requests return **HTTP 500**.

The request path is:

`shopper` (client) → `storefront` (nginx, `proxy_pass http://orders:8080`) → Service `orders` → orders pods

The 500s are created in the `orders` backend tier. Storefront only passes them through.

## 2. Root cause

On 2026-10-21 at 19:29:24Z, a new Deployment **`orders-fastpath`** was created in `shop`. It causes the failures in two ways:

- **Its pods carry the label `app=orders`** (full label set `{app: orders, track: fastpath}`). The `orders` Service selects pods by `app=orders` alone, so the canary pod became a **third endpoint** of the production `orders` Service.
- **Its container runs with `-status-code=500`** (args `-listen=:8080 -text=order accepted -status-code=500`). Every request it receives therefore returns 500.
- **It has no readiness probe**, so it began receiving traffic as soon as it started.

The Deployment's own annotations say `description: "Canary of the new orders fast path. Not wired into the storefront yet."` and `owner: payments-team`. That claim is false: because the canary shares the label, it is wired in, and it gets about 1/3 of production checkout traffic.

## 3. Evidence

- **EndpointSlice `orders-525sv`** (Service `orders`):
  `10.244.0.122, 10.244.0.121, 10.244.0.127`
  - .121 and .122 are the stable pods `orders-574f6fc5b9-cs29x` and `orders-574f6fc5b9-m8nvs`.
  - **.127 is the canary pod `orders-fastpath-8476ddbc8b-ht6z6`.**
- **Container args:**
  - `orders`: `["-listen=:8080","-text=order accepted"]`
  - `orders-fastpath`: `["-listen=:8080","-text=order accepted","-status-code=500"]`
- **Status codes in each pod's log:**

  | Pod | Responses |
  |---|---|
  | `orders-574f6fc5b9-cs29x` | 84 × 200 |
  | `orders-574f6fc5b9-m8nvs` | 72 × 200 |
  | `orders-fastpath-…-ht6z6` | **32 × 500**, all of them; e.g. `19:32:21 "GET /checkout" 500` from storefront pod 10.244.0.128 |

- **Shopper log:**
  - All responses were 200 until 19:29:46Z, which is the first 500.
  - 154 × 200 and 31 × 500 at the time of the RCA. The 31 failures match the canary pod's 32 × 500.
  - In the 2 minutes before 20:04:44Z there were 39 × 200 and 20 × 500, so the failure rate was still about 1/3.
- **Storefront access log** shows the 500s passing through, e.g. `19:30:30 "GET /checkout" 500 15`.
- **Ruled out:**
  - No NetworkPolicies in the cluster.
  - No OOMKills and no restarts on orders, storefront or shopper.
  - All referenced ConfigMaps and Secrets exist.
  - The `orders` Deployment is unchanged (still revision 1).
  - The storefront rollout at 19:30:25Z was only a `rollout restart` (it changed just the `restartedAt` annotation), and it had no effect.

## 4. Timeline (UTC, 2026-10-21)

| Time | Event |
|---|---|
| 19:26:23 | `orders`, `storefront`, `shopper` and `newsletter` are created. Checkouts return 200; there is one `000` during startup. |
| **19:29:24** | **`orders-fastpath` is created (scaled 0 → 1). Its pod joins the `orders` Service endpoints.** |
| 19:29:46 | First checkout 500 in the shopper log. |
| 19:30:25 | `storefront` is restarted (revision 2, no spec change). The 500s continue. |
| ~19:48 | Remediation attempt 1: the approval request for `kubectl scale` timed out, and nothing was changed. |
| ~19:50–20:04 | Remediation attempt 2: two more approval requests timed out, and nothing was changed. |
| 20:04:44 | Checkouts are still failing at about 1/3 (last 500 seen at 20:04:42.99Z). |

## 5. Fix

### Immediate fix (approved for use, not yet executed)
```
kubectl -n shop scale deployment/orders-fastpath --replicas=0
```
- This removes the canary pod from the `orders` endpoints straight away.
- It does not touch the stable `orders` Deployment or Service.
- It keeps the canary Deployment object for payments-team.
- To undo it: `kubectl -n shop scale deployment/orders-fastpath --replicas=1`.

**Execution status: NOT APPLIED.** KAOP holds the Shop Remediator's `kubectl scale` call for human approval. Three approval requests across two runs timed out without an answer, and KAOP lets these holds be answered only in its UI (on the run page), not from MCP or chat. The cluster is still in the failing state.

### Permanent fix (for payments-team / the service owners)
Use either option:

1. **Give the canary its own labels.** Recreate `orders-fastpath` with pod labels and a selector such as `{app: orders-fastpath, track: fastpath}`. The selector can't be changed in place, so the Deployment has to be recreated.
2. **Pin the Service to the stable pods.**
   - Add `track: stable` to `deploy/orders` `spec.template.metadata.labels`.
   - Wait for the rollout to finish.
   - Then change `svc/orders` `spec.selector` to `{app: orders, track: stable}`.

   Doing it in this order means the Service never has zero endpoints.

In addition:
- Remove `-status-code=500` from the canary, and give it a readiness probe, before it takes real traffic.
- Make sure canaries never reuse production Service selector labels.

## 6. Verification

**Not yet completed**, because the fix has not been applied.

After the scale command is approved or run, verify with:
```
kubectl -n shop get endpointslices -l kubernetes.io/service-name=orders -o wide
#   expected: only 10.244.0.121,10.244.0.122
kubectl -n shop logs deploy/shopper --timestamps --since=2m
#   expected after 60-90s: only 200s, zero 500s
```

## 7. Unrelated finding
`newsletter` is in CrashLoopBackOff: it logs `smtp relay unreachable` for `mail.internal:25` and exits 1. It is not in the checkout path and needs a separate fix for the SMTP relay connection.
