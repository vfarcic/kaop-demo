# Follow-up: shop checkout fix

I continued the original Slack conversation (run `run_a06117eba326617c1e2c52f8`) with the same agent in the same session (`slack:CSFMLBLKH:1792628485.171369`), so it kept its context from the original investigation.

Follow-up run: `run_b3b59470eb96473475ff2531` (succeeded)

## What I asked

> Check that the fix you applied is still holding, and tell me exactly how to roll it back.

## What it answered

The fix is still working. Every checkout since 00:28:13 has succeeded, and the broken canary has received no requests.

### Current state (checked 00:31 UTC)

| Check | Result |
|---|---|
| `orders` Service selector | `app=orders, track=stable` |
| `orders` Deployment | 2/2 ready, revision 2, pods labelled `track=stable` |
| `orders` Service endpoints | `10.244.0.157`, `10.244.0.158`: only the two normal pods. The canary (`10.244.0.154`) is not included. |
| Shopper checkouts 00:28:15–00:31:42 | 104 succeeded, 0 failed |
| Requests reaching `orders-fastpath` since the fix | 0; its last request was at 00:28:13 |

The shopper's 10-minute log still shows 73 failures, but all of them happened before the fix.

### How to roll it back

Undo the two changes in the reverse order. If you remove the label from the pods first while the Service still requires `track=stable`, the Service has no pods to send to and every checkout fails.

**Step 1: put the Service selector back.** This step alone fully restores the old behaviour:

```sh
kubectl patch service orders -n shop --type=json \
  -p '[{"op":"remove","path":"/spec/selector/track"}]'
```

**Step 2: take the label off the `orders` pods.** This is optional; the extra label does no harm once step 1 is done. Revision 1 is the template from before the fix, and the rolling update causes no downtime:

```sh
kubectl rollout undo deployment/orders -n shop --to-revision=1
kubectl rollout status deployment/orders -n shop
```

**Check the rollback worked:**

```sh
kubectl get svc orders -n shop -o jsonpath='{.spec.selector}'    # {"app":"orders"}
kubectl get endpointslices -n shop -l kubernetes.io/service-name=orders -o wide   # 3 IPs, including the canary
```

Rolling back will bring the failures back: `orders-fastpath` is still running and still answers every request with a 500. With three endpoints again, about one in three checkouts would fail. Only roll back once payments-team has scaled the canary down, fixed it, or changed its labels.

### Make the fix permanent

I applied the fix with `kubectl patch` directly in the cluster, so the shop's stored manifests don't include it. Running `kubectl apply` with the old manifests won't remove it, but the fix will be missing if anything recreates `orders` from those manifests. To keep it, add `track: stable` to the `orders` pod template and the `orders` Service selector in the shop's manifests.
