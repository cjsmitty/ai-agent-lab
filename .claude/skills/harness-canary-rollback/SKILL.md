---
name: harness-canary-rollback
description: The Harness NextGen K8s Canary deployment pattern — Canary + Primary step groups, health-based verification gating, failure strategy with automated Rollback Stage, and templatization. Use when building or reviewing the Harness pipeline for the canary auto-rollback demo.
---

# Harness Canary + Automated Rollback Pattern

Encodes the Harness NextGen Kubernetes **Canary** execution strategy so the pipeline is right the first time. Verify current YAML syntax against developer.harness.io before finalizing — do not trust memory for field names.

## Structure Harness generates (use it, don't hand-roll)

**CD stage → Deployment Type: Kubernetes → Execution Strategy: Canary** produces:

1. **Canary Deployment step group**
   - `K8sCanaryDeploy` — deploys N pods/percentage of the new version as a separate `-canary` workload. **Waits for steady state**: if readiness probes never pass, this step FAILS. This is the verification gate — probe failure = step failure, no extra config needed for the basic demo.
   - `K8sCanaryDelete` — removes the canary workload after evaluation.
2. **Primary Deployment step group**
   - `K8sRollingDeploy` — only reached if the canary group succeeded.

## The money moment: failure strategy
On the CD stage (or the canary step): **On step failure → Rollback Stage.** With `FAILURE_MODE != none`, K8sCanaryDeploy times out waiting for steady state → failure strategy fires → Harness runs the Rollback section (deletes the canary; the prior primary was never touched and keeps serving). Zero downtime, visible on the chat UI status bar.

Key settings:
- Set the K8sCanaryDeploy **step timeout short** (3–5m) — that timeout IS the time-to-rollback on stage.
- Rollback section is auto-generated (Canary Delete / rollback steps); keep it.
- Optionally add a Harness **Verify** step (Continuous Verification) after canary for the "liveness can't catch AI quality regressions" story — mention it even if not wired.

## Constraints & prereqs
- **Canary supports exactly ONE managed Deployment workload** in the manifests. Keep `k8s/` to a single Deployment.
- Service (K8s type) points at the repo's `k8s/` manifests via the GitHub connector; artifact = DockerHub image, tag `<+pipeline.sequenceId>` flowing from the CI stage.
- `FAILURE_MODE` should be a **service variable** overriding the ConfigMap value (manifests can reference `<+serviceVariables.failure_mode>`), so flipping it is a runtime pipeline input — the same image deploys healthy or broken.
- Delegate must run in (or reach) the GKE cluster and show HEALTHY before any CD run.
- CI stage: run pytest before build; build+push via DockerHub connector; fail the pipeline on test failure.

## Templatization (bonus story)
Extract the canary deploy+verify step group (or the CI test step) as a **Step Group Template** in Harness (Account/Org/Project scope), version it, reference from the pipeline. Pitch: every AI service team ships through the same verified canary gate. Keep the exported template YAML in the playback doc — NOT in the git repo.
