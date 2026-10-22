# Incident Report: Intermittent checkout failures in `shop` namespace (cluster `kaop`)

**Date:** 2026-10-19
**Status:** Root cause found. **Fix NOT yet applied** (no write access available, see "Fix").
**Analysis source:** KAOP agent "Kubernetes RCA (kaop)" (read-only kubectl inside the cluster).

## What failed
- About **1 in 3** `GET /checkout` requests through `storefront` (nginx) return **HTTP 500**.
- `storefront` is not the source of the errors. It passes the 500 through from its upstream, Service `orders` (`proxy_pass http://orders:8080`).
- The failing backend is pod `orders-fastpath-8476ddbc8b-5fc7v` (10.244.0.86), from Deployment `orders-fastpath`.

## Root cause
The `orders-fastpath` canary Deployment (owner annotation: payments-team) was created with pod labels `{app: orders, track: fastpath}`. The `orders` Service selects on `app=orders` alone, so the canary pod was added to the production `orders` endpoints. The canary container runs with `-status-code=500`, so every request that lands on it fails.

The canary's own annotation says *"Canary of the new orders fast path. Not wired into the storefront yet."* That is false: the label overlap wires it in.

With 3 ready endpoints (2 stable and 1 canary), about 33% of checkouts fail.

## Evidence
- **Service selector:** `svc/orders` uses `app=orders`.
- **EndpointSlice for `orders`:** 3 ready endpoints: `.80` and `.81` (`orders-574f6fc5b9-*`, stable) and `.86` (`orders-fastpath-8476ddbc8b-5fc7v`).
- **Canary spec:**
  - Labels: `{app: orders, track: fastpath}`
  - Args: `["-listen=:8080","-text=order accepted","-status-code=500"]`
  - Stable `orders` uses the same image without `-status-code` and returns 200.
- **Canary logs (all 500s):**
  `2026/10/19 18:45:28 orders:8080 10.244.0.83:57090 "GET /checkout HTTP/1.1" 500 15`
  `2026/10/19 18:48:31 orders:8080 10.244.0.87:57072 "GET /checkout HTTP/1.1" 500 15`
- **Stable orders logs:** only 200s, e.g. `18:48:29 ... "GET /checkout HTTP/1.1" 200 15`.
- **Storefront access log:** 500s with the same 15-byte body as the canary's responses:
  `[19/Oct/2026:18:48:31 +0000] "GET /checkout HTTP/1.1" 500 15`
- **Shopper synthetic probe** (`curl http://storefront/checkout` every 2s):
  - 18:42:22–18:45:26: all 200s.
  - First 500 at **18:45:28**, 6 seconds after the canary started.
  - Since then, 29 of ~94 requests failed (~31%).
- **No NetworkPolicies** in the namespace, and no Secret references, so neither plays a part.

## Timeline (UTC, 2026-10-19)
| Time | Event |
|---|---|
| 18:42:22 | Namespace workloads created: `orders` (2 replicas), `storefront`, `shopper`, `newsletter`, Service `orders`, ConfigMap `storefront`. All checkouts return 200. |
| **18:45:22** | **`orders-fastpath` created (RS 8476ddbc8b). Its pod joins the `orders` endpoints. (Trigger)** |
| 18:45:28 | First checkout 500, in both the canary log and the shopper probe |
| 18:46:23 | ConfigMap `storefront` re-applied, then `kubectl rollout restart deploy/storefront` (rev 2). Looks like a mitigation attempt. The only template change is the `restartedAt` annotation. The error rate did not change, so this is not the cause. |
| 18:46:23 → now | Failure rate stays at about one third |

## Fix
**Immediate mitigation** (reversible, removes the canary from the `orders` endpoints):
```sh
kubectl scale deploy/orders-fastpath -n shop --replicas=0
```

**Permanent fix:** give the canary labels that do not match the stable Service selector. The Deployment selector is immutable, so the Deployment has to be recreated:
```sh
kubectl delete deploy/orders-fastpath -n shop
# re-apply with:
#   spec.selector.matchLabels: {app: orders-fastpath, track: fastpath}
#   spec.template.metadata.labels: {app: orders-fastpath, track: fastpath}
# and remove "-status-code=500" before the canary is intentionally routed traffic.
```
Alternative: label the stable pods `track: stable` and narrow the `orders` Service selector to `{app: orders, track: stable}`.

Also: add review or admission checks so that new Deployments cannot match existing Service selectors by accident.

### Was the fix applied? **No.**
I could not apply it. This session had no shell or kubectl. The only cluster-connected agent in the KAOP workspace, "Kubernetes RCA (kaop)", is read-only, and the "KAOP Assistant" agent confirmed it has no cluster credentials. I did not change any agent's permissions to get write access, because that would be a privilege escalation nobody approved. Someone with write RBAC on `shop` needs to run the mitigation command above. The `orders-fastpath` canary is owned by payments-team, so tell them before you scale it down.

## Verification
**Not performed**, because the fix was not applied. To verify after applying it:
```sh
kubectl get endpointslice -n shop -l kubernetes.io/service-name=orders -o wide
#   expect only the orders-574f6fc5b9-* pod IPs (.80, .81)
kubectl logs deploy/shopper -n shop --since=2m
#   expect only 200 responses for /checkout
kubectl logs deploy/storefront -n shop --since=2m | grep ' 500 '
#   expect no output
```
The read-only RCA agent can also re-run these checks once the change is in place.

## Unrelated finding
`newsletter` is in **CrashLoopBackOff**. Its script logs `smtp relay unreachable, giving up` (mail.internal:25) and then always ends with `exit 1`, so it crashes even when the relay is reachable. It is not in the checkout path. To fix it, remove the unconditional `exit 1` and make the SMTP relay resolvable and reachable.
