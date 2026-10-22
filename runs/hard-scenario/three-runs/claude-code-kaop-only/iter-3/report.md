# Incident Report: Intermittent checkout failures in namespace `shop`

**Date:** 2026-10-19 · **Cluster:** `kaop` · **Status:** Root cause found. **Fix NOT applied and NOT verified** (see "Fix applied").

## What failed
About 1 in 3 checkout requests (`GET /checkout` on `storefront`) returns **HTTP 500**. The rest succeed. `storefront` (nginx) sends every request to the `orders` Service, and one of the three pods behind that Service always returns 500.

## Root cause
The **`orders-fastpath`** canary Deployment, created at 19:03:26Z, gives its pods the label `app=orders`. That matches the selector of the production `orders` Service (`app=orders`), so the canary pod was added to the Service's endpoints and gets a share of real traffic. Its container (http-echo) is hard-coded to return 500 (`-status-code=500`). It has no readiness probe, and the 500 is the app's normal response, so the pod reports Ready and is never removed from the endpoints.

The Deployment's annotation says *"Canary of the new orders fast path. Not wired into the storefront yet."* (owner: `payments-team`). That is wrong: the shared `app=orders` label is what wires it in.

## Evidence
(Collected through KAOP's in-cluster agent `Kubernetes RCA (kaop)`, which runs read-only kubectl.)
- **`orders-fastpath` spec:** pod labels `{"app":"orders","track":"fastpath"}`; args `["-listen=:8080","-text=order accepted","-status-code=500"]`.
- **`orders` EndpointSlice:** 3 ready endpoints:
  - `10.244.0.98` and `10.244.0.99`: `orders-574f6fc5b9-*`, healthy.
  - `10.244.0.104`: `orders-fastpath-8476ddbc8b-nt5qx`, `ready=true`, always returns 500.
- **ConfigMap `storefront`:** `location / { proxy_pass http://orders:8080; }`, so all checkout traffic is spread across all 3 pods.
- **`shopper` log** (synthetic checkout loop):
  - From 19:00:28 to 19:03:33: only 200s.
  - First 500 at 19:03:35.
  - After that: 60× 200 and 40× 500 (40%, close to the expected 1 in 3).
- **`storefront` access logs:** both nginx pods show 500s at about the same rate (22/13 and 16/14). That rules out a single bad nginx pod and points downstream of nginx.

## Timeline (UTC, 2026-10-19)
| Time | Event |
|---|---|
| 19:00:25 | `orders` (2 replicas), `storefront` rev 1, `shopper`, `newsletter` and ConfigMap `storefront` created |
| 19:00:26 | One `000` from shopper while storefront was starting (harmless) |
| 19:03:26 | `orders-fastpath` Deployment created; ReplicaSet `8476ddbc8b` scaled from 0 to 1 |
| 19:03:27 | Fastpath pod Ready and added to the `orders` endpoints |
| 19:03:35 | First checkout 500; failures continue at ~1 in 3 |
| 19:04:26 | `storefront` rolls to rev 2 (a restart only; not the cause) |

## Checked and not related
- **`storefront` rev 2:** the only template change is the `kubectl.kubernetes.io/restartedAt` annotation. It happened after the 500s had already started.
- **`newsletter` CrashLoopBackOff:** `smtp relay unreachable, giving up`, and its command always ends in `exit 1`. It is not on the checkout path. It is a separate issue: either it should be a Job, or `mail.internal:25` needs fixing.
- **Other checks:** there are no NetworkPolicies or Ingresses in `shop`, and the stable `orders` pods have 0 restarts.

## Fix
**Immediate fix (recommended):**
```
kubectl scale deploy/orders-fastpath -n shop --replicas=0
# or: kubectl delete deploy/orders-fastpath -n shop
```

**Long-term fixes:**
- Recreate the canary with its own labels (`app: orders-fastpath, track: fastpath`). `spec.selector` is immutable, so it has to be recreated rather than edited. Remove `-status-code=500` and add a readiness probe before any traffic is routed to it.
- Optionally, pin the `orders` Service to stable pods:
  1. Add `track: stable` to the `orders` pod template.
  2. Wait for that rollout to finish.
  3. Then patch the Service selector to `{app: orders, track: stable}`.

  The order matters: patching the Service first would leave it with zero endpoints.

## Fix applied
**Not applied.** This session had no way to change the cluster:
- No shell or kubectl access was available.
- The only cluster-connected KAOP agent (`Kubernetes RCA (kaop)`) is read-only by design.
- The `KAOP Assistant` agent confirmed it has no write access to the `kaop` cluster.

Someone with write access to `kaop` needs to run the immediate fix above.

## Verification
**Not performed**, because no fix was applied. Once the fix is applied, verify with:
1. `kubectl get endpointslices -n shop -l kubernetes.io/service-name=orders` should list only the two `orders-574f6fc5b9-*` IPs (`10.244.0.98`, `10.244.0.99`).
2. `kubectl logs -n shop deploy/shopper --since=2m` should show only `200` responses.
3. Optionally, re-run the `Kubernetes RCA (kaop)` agent to confirm the endpoints and shopper results without write access.
