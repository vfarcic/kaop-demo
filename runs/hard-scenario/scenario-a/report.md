# Incident report: intermittent checkout failures in the `shop` namespace

**Date:** 2026-10-19 (all times UTC)
**Status:** Mitigated. Checkouts return 200; follow-up needed from payments-team.
**Tooling:** Komodor Agentic Operations Platform (KAOP). The agent `Kubernetes RCA (kaop)` did the read-only investigation and verification. The agent `Shop Remediator` applied the fix.

## 1. What failed

About **1 in 3** customer checkouts (`GET /checkout` through `storefront`) returned **HTTP 500**. The rest succeeded. Both storefront replicas showed the failures, so neither replica was the problem on its own.

Request path: customer → `storefront` (nginx, proxies to `http://orders:8080`) → `orders` Service → backend pods.

## 2. Root cause

At 21:34:57 someone created a canary Deployment, `orders-fastpath` (owner annotation: payments-team). Its pod template has the labels **`app: orders, track: fastpath`**. The `orders` Service selects pods on **`app=orders` only**, so the canary pod became a third endpoint of the live `orders` Service and got about a third of checkout traffic.

The canary container is `hashicorp/http-echo:1.0.0` with args `-listen=:8080 -text="order accepted" -status-code=500`, so **it answers every request with HTTP 500**. Its annotation says *"Canary of the new orders fast path. Not wired into the storefront yet."* That is wrong: the label overlap is what put it in the storefront's traffic.

In short, the canary's labels overlapped with the production Service selector, and it went live with a hard-coded 500 response.

## 3. Evidence

- **Service endpoints before the fix:** `orders` → `10.244.0.108:8080, 10.244.0.109:8080, 10.244.0.114:8080`
  - `.108` and `.109` are `orders-574f6fc5b9-*`, the stable pods. They have no `-status-code` arg and always return 200.
  - `.114` is `orders-fastpath-8476ddbc8b-62lwn`, the canary. It was Ready and therefore received traffic.
- **Canary logs:** `"GET /checkout HTTP/1.1" 500` for requests from both storefront pods (`10.244.0.115`, `10.244.0.116`).
- **Stable `orders` logs:** only 200s on `/checkout`, and 0 restarts.
- **Synthetic client (`deploy/shopper`)**, last 200 checks before the fix: 155 × 200, 28 × 500, 1 × 000. The single 000 was at 21:31:56, during startup. The **first 500 was at 21:35:02**, 5 seconds after the canary pod started.
- **Storefront logs:** both pods logged 500s on `/checkout` (25 OK / 7 × 500 and 23 OK / 9 × 500).
- **Ruled out:**
  - There are no NetworkPolicies.
  - Container images did not change (`nginx:1.31.7`, `hashicorp/http-echo:1.0.0`).
  - The storefront endpoints were healthy.
  - The storefront rollout restart at 21:35:57 came *after* the first 500 and did not change the failure rate.

## 4. Timeline (UTC)

| Time | Event |
|---|---|
| 21:31:55 | `orders`, `storefront` (rev 1), `shopper`, `newsletter` created. Checkouts return 200. |
| 21:34:57 | `deploy/orders-fastpath` created (RS `8476ddbc8b`). Its pod joins the `orders` Service endpoints. |
| 21:35:02 | First checkout 500. About a third of requests fail from here on. |
| 21:35:57 | `storefront` rollout restart (rev 2, RS `599d55d787`) and its ConfigMap re-applied. Did not fix the failures and was not the cause. |
| ~21:38:00 | Root-cause analysis finished (KAOP `Kubernetes RCA (kaop)`). |
| 21:38:55 | Last observed 500. |
| 21:38:56 | Fix applied: `orders-fastpath` scaled to 0 and the canary pod killed. |
| 21:39:00 → 21:39:57 | Verification: every checkout request returns 200. |

## 5. Fix applied

The smallest reversible change: the Deployment is kept, only its replica count is changed.

```
$ kubectl scale deploy/orders-fastpath -n shop --replicas=0
deployment.apps/orders-fastpath scaled
$ kubectl wait --for=delete pod -n shop -l app=orders,track=fastpath --timeout=90s
exit=0
```

I changed nothing else. I didn't delete the Deployment, because payments-team owns it.

## 6. Verification

The KAOP RCA agent checked this independently, read-only, after the fix:

- **`orders` endpoints:** `10.244.0.108:8080,10.244.0.109:8080`. These are only the stable `orders-574f6fc5b9` pods. No other `app=orders` pods exist.
- **`kubectl get deploy -n shop`:** `orders 2/2`, `orders-fastpath 0/0`, `storefront 2/2`, `shopper 1/1`.
- **Shopper synthetic checks after 21:39:00:** 25 × 200, 0 errors. The last 500 was at 21:38:55, one second before the canary pod was killed.
- **Storefront `/checkout` after 21:39:00:** 29 × 200 across both pods (14 + 15), 0 errors.

**Limitation:** the verification window was short, about 1 minute and roughly 25–30 requests. Before about 1 in 3 requests failed, so this many clean requests in a row is strong evidence the fix worked. Still, re-check the `shopper` logs over a longer period.

## 7. Follow-ups (recommended, not applied)

1. **payments-team:** before scaling `orders-fastpath` back up, give its pods labels that do not match the `orders` Service. For example, use `app: orders-fastpath`. The Deployment's selector can't be changed in place, so the Deployment must be recreated. Also remove `-status-code=500` before it takes any real traffic.
2. **Harden the Service:** add a distinguishing label such as `track: stable` to the stable `orders` pods and to the Service selector, so a future pod that reuses `app=orders` can't join production traffic by accident.
3. **Guardrail:** add a policy check (Kyverno, Gatekeeper or a CI lint) that flags new workloads whose pod labels match an existing Service selector they don't own.
4. **Unrelated issue found:** `deploy/newsletter` is in CrashLoopBackOff (`smtp relay mail.internal:25 unreachable`). It is not on the checkout path, but someone should look at it.
