---
name: k8s-probe-tuning
description: How to tune Kubernetes readiness/liveness probe timings so failures surface fast and predictably for canary/rollback demos — short periods, low thresholds, and the rationale. Use when writing or reviewing probe config in k8s manifests.
---

# K8s Probe Tuning for Fast, Predictable Demo Failures

**The demo lives or dies on time-to-fail.** If `failureThreshold × periodSeconds` is long, the on-screen rollback takes forever. Tune probes so a bad canary is declared failed in well under a minute.

## Recommended demo values

```yaml
readinessProbe:
  httpGet: { path: /ready, port: 8080 }
  initialDelaySeconds: 3
  periodSeconds: 5
  timeoutSeconds: 2      # must be < the latency failure-mode sleep (default 10s) so latency mode trips it
  failureThreshold: 2    # unready after ~10s of failure
  successThreshold: 1
livenessProbe:
  httpGet: { path: /healthz, port: 8080 }
  initialDelaySeconds: 5
  periodSeconds: 5
  timeoutSeconds: 2
  failureThreshold: 3    # restart after ~15s — slightly laxer than readiness so unready shows before restarts
```

## Rationale / rules
- **Readiness gates rollout; liveness restarts.** The canary verification watches readiness — that's what must fail fast. Keep readiness stricter (lower threshold) than liveness.
- Time-to-unready ≈ `initialDelay + failureThreshold × periodSeconds`. Compute it and say it out loud; target ≤ ~15s for the demo.
- `timeoutSeconds` is the lever for the `latency` failure mode: probe times out → counts as failure. Sleep (10s) must exceed timeout (2s).
- `healthz_500` trips via HTTP status ≥ 400; `crash_on_start` never passes `initialDelaySeconds` — pod CrashLoopBackOffs and the Deployment never progresses.
- **Also set the Deployment's `progressDeadlineSeconds` low (e.g. 60)** so a never-ready canary marks the rollout failed quickly — Harness's steady-state check keys off this. Default is 600s = a 10-minute stall on stage.
- Match the Harness canary step timeout to the math: probe-fail time + pod scheduling + image pull, plus margin — ~3–5 min is plenty; the default 10 min drags the demo.
- These are DEMO values. For production, note the trade-off: aggressive probes cause flapping under load spikes; real services want longer periods, higher thresholds, and startupProbes for slow boots.
