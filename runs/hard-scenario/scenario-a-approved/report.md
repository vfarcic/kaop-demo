# Incident Report: Intermittent checkout failures in the `shop` namespace

**Date:** 2026-10-21 (UTC)
**Status:** Mitigated and verified
**Tools used:** KAOP agents *Kubernetes RCA (kaop)* (read-only investigation) and *Shop Remediator* (applied the fix and verified it)

## 1. What failed

Some `GET /checkout` requests through the `storefront` returned **HTTP 500**. The rest succeeded.
- Measured by the RCA agent: 31 of 180 recent shopper requests returned 500. All of them came after the canary appeared, and the post-canary failure rate was about 1/3.
- Measured by the remediator over the whole window before the fix (23:24:47–23:33:10): 200 × 200, 50 × 500, 1 × 000. The 500 share looks lower here because this window includes about 3 minutes before the canary existed.

## 2. Root cause

Deployment `orders-fastpath` is a canary owned by `payments-team`. Its pod template carries the labels `app: orders, track: fastpath`. The `orders` Service selects only on `app=orders`, so the canary pod was added to the Service's endpoints next to the two healthy `orders` pods.

The canary container runs with `-status-code=500`, so it fails **every** request it gets. kube-proxy spreads traffic across all three endpoints, so roughly **1 in 3 checkouts** reached the canary and failed. That is why only some checkouts failed.

The canary's own annotation says *"Canary of the new orders fast path. Not wired into the storefront yet."* Not giving it its own Service did not keep it out of the path, because its labels overlap with the `orders` Service selector.

## 3. Evidence

- **Label overlap:** `deploy/orders-fastpath` has template labels `{app: orders, track: fastpath}`. `svc/orders` has selector `{app: orders}`.
- **Canary pod in the endpoints:** `endpoints/orders` = `10.244.0.139:8080, 10.244.0.140:8080, 10.244.0.145:8080`. `.145` is `orders-fastpath-8476ddbc8b-hn9hb`.
- **Canary is set to fail:** its args are `["-listen=:8080","-text=order accepted","-status-code=500"]`. The healthy `orders` pods have no `-status-code` argument.
- **Canary logs show storefront traffic reaching it:**
  `2026/10/21 23:30:37 orders:8080 10.244.0.146:53010 "GET /checkout HTTP/1.1" 500 15 "curl/8.23.0"`
  The sources `10.244.0.146` and `.147` are the storefront pods.
- **Storefront logs show the 500s passing through:** `"GET /checkout HTTP/1.1" 500 15`. Pod djgp6 had 9 of 36 checkouts fail; pod nzl9l had 8 of 23.
- **Timing:** the first 500 in the shopper logs is at 23:27:52, 4 seconds after `orders-fastpath` was created at 23:27:48.
- **Storefront config is not the cause:** ConfigMap `storefront` has `proxy_pass http://orders:8080;`, which is correct, and it has not changed since it was created.

## 4. Timeline (UTC, 2026-10-21)

| Time | Event |
|---|---|
| 23:24:46–47 | `orders`, `storefront`, `shopper`, `newsletter` and ConfigMap `storefront` created. Checkouts return 200. |
| **23:27:48** | **`orders-fastpath` canary created. Its pod (10.244.0.145) joins `endpoints/orders`.** |
| 23:27:52 | First checkout 500. |
| 23:28:48 | `storefront` restarted (rollout restart, rev 2, template otherwise unchanged). 500s continue, so the restart did not help. |
| 23:33:02 | Last 500 seen. |
| **23:33:11** | **Fix applied: `orders-fastpath` scaled to 0.** |
| 23:33:12 onward | Only 200s. |

## 5. Fix applied

```
kubectl -n shop scale deployment/orders-fastpath --replicas=0
```

This takes the faulty canary pod out of the `orders` Service. It is the smallest change that stops the failures and is easy to undo. The Deployment was **not** deleted (it belongs to payments-team), and nothing else was changed.

### Recommended permanent fix (payments-team)

Before the canary is scaled back up:
1. Give it labels the `orders` Service does not match, in **both** `spec.selector.matchLabels` and `spec.template.metadata.labels`. For example, use `app: orders-fastpath`. The selector field is immutable, so the Deployment has to be deleted and re-created. Another option is to make the Service selector stricter: `{app: orders, track: stable}`, with `track: stable` added to the `orders` pods.
2. Remove `-status-code=500` before the canary takes real traffic.

**Warning:** running `kubectl -n shop scale deployment/orders-fastpath --replicas=1` without step 1 will bring the failures back.

## 6. Verification

- `kubectl -n shop get deploy orders-fastpath` returns `0/0`, and no fastpath pod is running.
- `kubectl -n shop get endpoints orders` returns `10.244.0.139:8080,10.244.0.140:8080`, which are the two healthy `orders` pods only. The EndpointSlice matches.
- Checkout traffic: `kubectl -n shop logs deploy/shopper --since-time=2026-10-21T23:33:12Z` shows the shopper calling `storefront/checkout` about every 2 seconds:

| Window (UTC) | 200 | 500 | other |
|---|---|---|---|
| Before fix: 23:24:47–23:33:10 | 200 | 50 | 1 × 000 (startup race, unrelated) |
| **After fix: 23:33:12–23:34:17** | **33** | **0** | 0 |

**Limitation:** the remediator's service account cannot use `pods/exec`, so it did not curl individual pods. The check relies on the shopper's real ongoing checkout traffic.

## 7. Other findings (not related to checkouts)

- `newsletter` is in CrashLoopBackOff. Its script tries `mail.internal:25` and always ends with `exit 1`. It has no Service and is not in the checkout path. It needs its own fix and was left untouched.
- There are no NetworkPolicies, HPAs or PDBs in `shop`, and no workload references a Secret.
- The cluster records cannot tell who applied `orders-fastpath` or who restarted `storefront`.
