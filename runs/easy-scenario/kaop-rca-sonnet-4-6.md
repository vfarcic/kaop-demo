I have everything needed. The `orders` deployment has been at revision 1 since `15:35:40Z` with port `8080` throughout — it was never on 8081. The bug has existed from initial deployment, and the three `kubectl rollout restart` commands (revisions 2, 3, 4) were futile attempts to fix it without touching the config.

---

## Wrong upstream port in `storefront` ConfigMap — every checkout request times out with 504

**Resource:** Deployment/storefront in shop — currently 2/2 Ready (pods healthy; checkout broken)

### What happened
- Customers report checkout failures; every `GET /checkout` returns HTTP 504 Gateway Timeout.
- The storefront nginx pod proxies all traffic to `http://orders:8081`; the `orders` Service exposes **only port 8080** — the connection always times out (2 s `proxy_connect_timeout`).
- Three `kubectl rollout restart` commands (revisions 2, 3, 4) restarted the pods without fixing the ConfigMap, so the fault persists through all revisions.

### Evidence
- **Anchor — nginx error log (pod `storefront-77bdddd4b7-x6c98`, `16:30:48Z` onward, repeating every request):**
  ```
  upstream timed out (110: Connection timed out) while connecting to upstream,
  request: "GET /checkout HTTP/1.1",
  upstream: "http://10.96.101.90:8081/checkout"
  ```
  `10.96.101.90` is the `orders` Service ClusterIP. Every checkout hits this path and 504s.
- **ConfigMap `storefront` (the nginx vhost mounted at `/etc/nginx/conf.d`):**
  ```nginx
  location / {
    proxy_connect_timeout 2s;
    proxy_pass http://orders:8081;
  }
  ```
  Port `8081` is hardcoded.
- **`orders` Service** (`kubectl get service orders -n shop`): `port: 8080`, `targetPort: 8080`. There is no listener on 8081.
- **`orders` endpoints** (`kubectl get endpoints orders -n shop`): two healthy pods (`10.244.0.5:8080`, `10.244.0.6:8080`). The backend itself is up and serving — it is never reached.
- **`orders` Deployment**: revision 1 only, created `2026-10-19T15:35:40Z`, container port `8080`, never changed.
- **Storefront pods `storefront-77bdddd4b7-msrjn` and `-x6c98`**: 0 restarts, Running/Ready — readiness probe hits `/healthz` which returns 200 locally; it does not exercise the upstream, so pods pass readiness while every proxied request fails.

### Change timeline
| Time (UTC) | Event |
|---|---|
| `2026-10-19T15:35:40Z` | Initial deploy: `orders` (port 8080) and `storefront` rev 1 both created. ConfigMap already has `orders:8081` — bug present from day one. |
| `2026-10-19T15:36:07Z` | `kubectl rollout restart` → storefront rev 2 (annotation `restartedAt: 17:36:07+02:00`). No ConfigMap change. |
| `2026-10-19T15:36:43Z` | `kubectl rollout restart` → storefront rev 3. No ConfigMap change. |
| `2026-10-19T16:29:54Z` | `kubectl rollout restart` → storefront rev 4 (current). No ConfigMap change. |

No change to the `orders` Deployment or Service at any point. The ConfigMap cannot be version-diffed (Kubernetes retains no history), but the current value has always pointed to the wrong port — the `orders` service was never on 8081.

### Recommendation
Patch the `storefront` ConfigMap to correct the upstream port:

```yaml
# in ConfigMap storefront, data.default.conf:
proxy_pass http://orders:8080;
```

After applying the ConfigMap change, the running pods will pick up the updated volume mount within seconds (default `configmap` sync period ~1 min) without a restart. To force immediate pickup, trigger one more `kubectl rollout restart deployment/storefront -n shop` after the ConfigMap is updated.

### Confidence & limits
**High.** The nginx error log names the exact upstream IP and wrong port on every single failing request; the `orders` Service spec confirms port 8080; the ConfigMap shows port 8081. The mechanism is complete and verified.

Blind spot: who authored the ConfigMap with port 8081 (no audit log available in the cluster) and whether this was always wrong or was accidentally edited (no ConfigMap version history in Kubernetes).

---

```json rca-output
{
  "problem": "storefront ConfigMap sets nginx upstream to orders:8081 but the orders Service exposes only port 8080, causing every checkout request to time out with 504",
  "whatHappened": [
    "Every GET /checkout proxied by nginx returns HTTP 504 Gateway Timeout due to a 2s proxy_connect_timeout hitting orders:8081",
    "The orders Service (ClusterIP 10.96.101.90) binds only port 8080; port 8081 has no listener",
    "Three kubectl rollout restart commands (revisions 2–4) restarted storefront pods without correcting the ConfigMap, so the fault persists",
    "Readiness probe checks /healthz locally (returns 200); it does not test the upstream, so pods show Ready while all checkout traffic fails"
  ],
  "evidence": [
    "nginx error log pod storefront-77bdddd4b7-x6c98 16:30:48Z+: 'upstream timed out (110) connecting to upstream: http://10.96.101.90:8081/checkout' — repeating on every request",
    "ConfigMap storefront data.default.conf: proxy_pass http://orders:8081 (wrong port)",
    "kubectl get service orders -n shop: port 8080 / targetPort 8080 only — no 8081",
    "kubectl get endpoints orders -n shop: 10.244.0.5:8080, 10.244.0.6:8080 — backend healthy but unreachable on 8081",
    "orders Deployment: revision 1 since 2026-10-19T15:35:40Z, container port 8080, never changed"
  ],
  "recommendation": "Edit ConfigMap storefront in namespace shop: change proxy_pass http://orders:8081 to proxy_pass http://orders:8080. After applying, the volume mount updates within ~1 minute; run kubectl rollout restart deployment/storefront -n shop to force immediate pickup.",
  "confidence": "high"
}
```
