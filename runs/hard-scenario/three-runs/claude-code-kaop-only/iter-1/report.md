# Incident report: intermittent checkout failures in namespace `shop` (cluster `kaop`)

**Status: root cause found. Fix NOT applied and NOT verified (no write path available; see "Fix" below).**

## What failed

About 1 in 3 `GET /checkout` requests return **HTTP 500**.

Request path: shopper → `storefront` (nginx) → `proxy_pass http://orders:8080` → Service `orders`.

The `orders` Service had **3 ready endpoints**:

| Endpoint | Pod | Behaviour |
|---|---|---|
| 10.244.0.62 | `orders-574f6fc5b9-*` | healthy, returns 200 |
| 10.244.0.63 | `orders-574f6fc5b9-*` | healthy, returns 200 |
| 10.244.0.68 | `orders-fastpath-8476ddbc8b-hrncs` | **always returns 500** |

## Root cause

The `orders-fastpath` canary Deployment was created at 18:26:44Z. Its pod template carries the label `app=orders` (plus `track=fastpath`).

The `orders` Service selects on `app=orders` only, so it picked up the canary pod as a regular backend. The canary runs with `-status-code=500`, so it answers every request with a 500. Kube-proxy spreads traffic across the three endpoints, which means about 33% of checkouts land on the canary and fail.

The canary's own annotation says it is *"Not wired into the storefront yet"* (`owner: payments-team`). The shared label wired it in anyway.

## Evidence

- **Service selector:** `svc/orders` has selector `app=orders`.
- **Canary pod labels:** the `orders-fastpath` pod template has `{"app":"orders","track":"fastpath"}`.
- **EndpointSlice for `orders`:** includes `10.244.0.68 orders-fastpath-8476ddbc8b-hrncs ready=true`.
- **Canary args:** `["-listen=:8080","-text=order accepted","-status-code=500"]`.
- **Canary logs:** `"GET /checkout HTTP/1.1" 500 15`. The source IPs are the storefront pods.
- **Healthy `orders` pod logs:** 0 responses with status 500.
- **Storefront access logs:** `"GET /checkout HTTP/1.1" 500 15`. The 15-byte body is the same as the canary's response.
- **Shopper (synthetic client):**
  - Before 18:26:44, every response was 200.
  - The first 500 was at 18:26:46, 2 seconds after the canary was created.
  - After that: 69 × 200 and 28 × 500 (about 29%, close to 1/3).
- **Storefront revision 1 → 2:** the only difference is a `restartedAt` annotation. Image and ConfigMap are unchanged, and `proxy_pass http://orders:8080` is correct. The storefront is not the cause.

### Ruled out / unrelated

- **`newsletter`:** in CrashLoopBackOff because the SMTP relay `mail.internal:25` is unreachable and the script ends with an unconditional `exit 1`. Nothing in the checkout path depends on it. It needs its own ticket.
- **Network:** there are no NetworkPolicies, and the `storefront` endpoints are healthy.

## Timeline (UTC, 2026-10-19)

| Time | Event |
|---|---|
| 18:23:43 | `orders`, `storefront`, `shopper`, `newsletter` and ConfigMap `storefront` created. Checkouts return 200. |
| 18:26:44 | `orders-fastpath` Deployment and pod created. The pod joins the `orders` Service endpoints. |
| 18:26:46 | First checkout 500. |
| 18:27:44 | `kubectl rollout restart deploy/storefront` (revision 2). The 500s continue. |
| 18:29:53 | 500s still occurring (last observation). |

## Fix

### Applied

**None.** This session could reach the cluster only through KAOP:

- The only agent deployed in cluster `kaop`, "Kubernetes RCA (kaop)", has **read-only** kubectl access.
- The "KAOP Assistant" has no cluster or Komodor tools.
- None of the available agents expose the Komodor gateway (which includes Klaudia remediation).

I did not change agent permissions or gateway policies to give myself write access. That is a governance change and needs explicit approval.

### Recommended: immediate mitigation (run this first)

```bash
kubectl -n shop scale deploy/orders-fastpath --replicas=0
```

### Recommended: durable fix (choose one)

1. **Give the canary its own identity.** Recreate `orders-fastpath` with `app: orders-fastpath` in both the selector and the pod template. The Deployment selector is immutable, so the Deployment has to be deleted and re-applied.
2. **Tighten the stable Service.** Add `track: stable` to the pod template labels of the `orders` Deployment, then change `svc/orders` to `selector: {app: orders, track: stable}`. Add the template label **before** changing the Service selector, or the Service will be left with no endpoints.

Also recommended:

- Policy or admission check: a canary must not share the full selector set of an existing Service.
- Ticket for the payments team: the canary returns 500 by design.
- Separate ticket for `newsletter`.

## Verification

**Not performed**, because the fix could not be applied. Once someone with write access applies it, check:

```bash
# Only orders-574f6fc5b9-* IPs (10.244.0.62/.63) should be listed
kubectl -n shop get endpointslice -l kubernetes.io/service-name=orders -o wide
# Should show only 200s after the change
kubectl -n shop logs deploy/shopper --since=2m | grep -c ' 500 '
kubectl -n shop logs deploy/storefront --since=2m | grep checkout
```

Success means the `orders` endpoints contain no `orders-fastpath` pod and the shopper log shows 0 × 500 over several minutes.

## Sources

- KAOP run of agent "Kubernetes RCA (kaop)", read-only investigation of namespace `shop`.
- KAOP Assistant runs that confirmed there is no write or Komodor tool access.
