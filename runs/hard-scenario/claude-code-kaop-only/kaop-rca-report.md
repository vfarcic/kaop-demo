## Checkouts are failing intermittently because a canary Deployment, `orders-fastpath`, is wired into live checkout traffic via the shared `orders` Service — and it returns HTTP 500 by design

**Resource:** `service/orders` (and its backing `deployment/orders-fastpath`) in `shop` — partially unhealthy: serving ~1/3 checkout requests as 500

### What happened
- Customer-visible symptom: `storefront` → `/checkout` intermittently returns HTTP 500 (synthetic checker `shopper` shows 37/217 requests failing since onset).
- `deployment/orders` serves `/checkout` behind `service/orders`, selected by label `app=orders`.
- At 17:21:03Z a second Deployment, `orders-fastpath`, was created with labels `app=orders, track=fastpath` — annotated "Canary of the new orders fast path. **Not wired into the storefront yet**." and owned by `payments-team`.
- Because `service/orders`'s selector is only `app=orders` (not also `track`), it matches `orders-fastpath`'s pod too, adding it as a third backend endpoint immediately on creation — contradicting the deployment's own annotation.
- That canary container is `hashicorp/http-echo` started with `-status-code=500`, so every request routed to it fails, while the two real `orders` pods return 200. This yields the observed ~1-in-3 failure rate.

### Evidence
- **Anchor:** `kubectl get endpointslice -l kubernetes.io/service-name=orders -o json` lists three ready/serving backends for `service/orders`: `10.244.0.41` and `.42` (pods `orders-574f6fc5b9-*`) and `10.244.0.47` (pod `orders-fastpath-8476ddbc8b-fr87p`) — confirming the canary is live in the Service despite the "not wired in" annotation.
- `deployment/orders-fastpath` container args: `["-listen=:8080","-text=order accepted","-status-code=500"]` (`kubectl get deploy orders-fastpath -o json`) — the pod is intentionally built to return 500.
- `deployment/orders-fastpath` annotation: `"description": "Canary of the new orders fast path. Not wired into the storefront yet."`, `"owner": "payments-team"`.
- `service/orders` selector is `{"app":"orders"}` only (`kubectl get svc orders -o json`); `orders-fastpath` pod labels are `{"app":"orders","track":"fastpath"}` — the missing `track` scoping in the selector is why it matches.
- `orders-fastpath-8476ddbc8b-fr87p` logs: every logged request is `"GET /checkout HTTP/1.1" 500 15` (`kubectl logs orders-fastpath-8476ddbc8b-fr87p`).
- `orders-574f6fc5b9-{t97cd,2gx5v}` logs: all logged requests are `"GET /checkout HTTP/1.1" 200 15` — the two legitimate pods are healthy.
- `shopper-67fc9594cb-d8rqd` synthetic-check log (polls `storefront/checkout` every 2s): clean `200`s from 17:18:03Z through 17:21:03Z, then first `500` at **17:21:05Z**, with 37 total 500s through 17:24:50Z.
- `orders-fastpath` pod `startTime: 2026-10-19T17:21:03Z`, `Ready` condition `True` at `2026-10-19T17:21:05Z` — matches the checker's first failure to the second.
- Separately, `deployment/newsletter`'s single pod is `CrashLoopBackOff` (`restartCount: 6`), logs: `"connecting to smtp relay mail.internal:25"` / `"smtp relay unreachable, giving up"`. Unrelated to checkout — no Service/selector overlap with `orders`/`storefront`, and it is its own, independently-failing workload (SMTP relay `mail.internal` unreachable from the pod).

### Change timeline
- `17:18:02Z` — namespace baseline created: `orders` (rev 1, 2/2 Ready), `storefront` (rev 1), `shopper`, `newsletter` all rolled out together. Checkout clean (200s) from the start.
- `17:21:03Z` — `deployment/orders-fastpath` created (revision 1) by `payments-team`, selector `app=orders,track=fastpath`, 1 replica, container pre-configured with `-status-code=500`. Pod `orders-fastpath-8476ddbc8b-fr87p` scheduled and ready by `17:21:05Z`.
- `17:21:05Z` — first checkout `500` observed by the synthetic checker — onset coincides exactly with the canary pod becoming `Ready` and joining `service/orders`'s endpoints (Service selector was never scoped to exclude it).
- `17:22:04Z` — unrelated: `storefront` rolled to revision 2 (no spec diff found between rev 1 and rev 2 container specs — likely a no-op/metadata-only re-apply); does not change checkout behavior.
- No change found to `service/orders`'s selector, `deployment/orders`, or the `storefront` nginx ConfigMap in this window — the only change that explains the failure onset is the `orders-fastpath` creation.

### Recommendation
- Immediate: have `payments-team` either scale `orders-fastpath` to 0 replicas, or correct `service/orders`'s selector to also require `track: stable` (and label the real `orders` pods accordingly) so the canary's `app=orders` label no longer matches it. This is a workload/Service spec change — recommend only, do not apply.
- Before re-enabling the canary: remove the hardcoded `-status-code=500` test arg from `orders-fastpath`, and wire it in deliberately (e.g. via a separate Service/route or a correctly scoped label selector) rather than relying on the shared `orders` Service's broad selector.

### Confidence & limits
- **High.** The failure mechanism (selector over-match → 500-only pod in rotation), the exact onset timestamp, and the causal change (creation of `orders-fastpath`) are all directly confirmed by EndpointSlice, Deployment spec, and pod logs — no inference required.
- Not knowable from the cluster: who at `payments-team` applied this deployment (only the annotation records the team, not an identity/actor), and whether this was deployed in error or the Service selector gap was a pre-existing latent bug waiting for any `app=orders` pod to trigger it.

```json rca-output
{
  "problem": "service/orders has an unscoped selector (app=orders) that also matches the payments-team canary deployment/orders-fastpath, whose http-echo container is hardcoded to return HTTP 500; it joined the Service's endpoints the moment it became Ready, causing ~1/3 of /checkout requests to fail.",
  "whatHappened": [
    "Customers see intermittent 500s on checkout; synthetic checker shows 37/217 failed /checkout requests since 2026-10-19T17:21:05Z",
    "deployment/orders-fastpath (revision 1) was created at 2026-10-19T17:21:03Z by payments-team, annotated 'Canary ... Not wired into the storefront yet', with container arg -status-code=500",
    "service/orders selects only on app=orders, which orders-fastpath's pod also carries (plus track=fastpath), so it was added as a live backend despite the annotation",
    "Two real orders pods return 200 for every request; the fastpath pod returns 500 for every request it receives, producing the ~1-in-3 failure rate",
    "First synthetic 500 (17:21:05Z) matches the fastpath pod's Ready transition (17:21:05Z) to the second"
  ],
  "evidence": [
    "EndpointSlice for service/orders lists 3 ready backends: orders-574f6fc5b9-t97cd (10.244.0.41), orders-574f6fc5b9-2gx5v (10.244.0.42), orders-fastpath-8476ddbc8b-fr87p (10.244.0.47)",
    "deployment/orders-fastpath container args: [-listen=:8080, -text=order accepted, -status-code=500]; annotation says 'Not wired into the storefront yet'; owner=payments-team",
    "service/orders selector {app: orders} matches orders-fastpath pod labels {app: orders, track: fastpath} -- the missing track scoping is the root defect",
    "orders-fastpath-8476ddbc8b-fr87p logs: every /checkout request logged as 500; orders-574f6fc5b9-* pods log 200 for every /checkout request",
    "shopper synthetic checker: clean 200s 17:18:03Z-17:21:03Z, first 500 at 17:21:05Z, 37 total 500s through 17:24:50Z",
    "orders-fastpath pod startTime=2026-10-19T17:21:03Z, Ready=True at 2026-10-19T17:21:05Z, matching checkout failure onset",
    "Unrelated: deployment/newsletter pod in CrashLoopBackOff (restartCount 6) due to 'smtp relay unreachable' connecting to mail.internal:25 -- no selector/Service overlap with checkout path"
  ],
  "recommendation": "Scale deployment/orders-fastpath to 0 (or scope service/orders's selector to exclude track=fastpath, e.g. require track: stable) to remove the 500-only pod from t...[truncated 224 chars]
