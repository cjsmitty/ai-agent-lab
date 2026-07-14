# Harness AI Agent Lab

## What this is

A small AI agent app (FastAPI + Gemini on Vertex AI) used to demo **Harness CI/CD canary deployments with automated rollback** on GKE. The trick: failure is a **config toggle**, not a code change. The same container image ships healthy or broken depending on one env var (`FAILURE_MODE`), so you can deploy a deliberately bad canary, watch its health probes fail, and watch Harness roll it back — live, on screen, via the app's own chat UI status bar. Infra is throwaway Terraform (cheap zonal GKE, spot nodes) that you stand up before a demo and **destroy immediately after**.

Flow: clone → run locally → `terraform apply` GKE → deploy via Harness → flip `FAILURE_MODE` → watch auto-rollback → `terraform destroy`.

## Architecture

```
Browser (chat UI + status bar)
   │  same-origin fetch
   ▼
Service (LoadBalancer :80) ──► Pod :8080  FastAPI
                                 ├── GET  /healthz   liveness  (the rollback trigger)
                                 ├── GET  /ready     readiness (validates provider config)
                                 ├── GET  /version   version + BUILD_FLAVOR + failure_mode
                                 ├── POST /agent     tool-using agent (calculator + lookup)
                                 └── GET  /          static chat UI (app/static/)
                                 │
                                 └── Workload Identity ──► Vertex AI (Gemini)
```

- **Agent:** one-shot loop — the LLM decides `TOOL: calculator|lookup` or `ANSWER:`; tools run server-side. Two providers: `stub` (deterministic, network-free — default, local dev needs zero GCP) and `vertex` (Gemini via the `google-genai` SDK).
- **Auth: NO LLM API KEYS. ANYWHERE.** In-cluster the pod calls Vertex AI via **Workload Identity**: KSA `ai-agent/ai-agent-sa` is annotated to impersonate GCP SA `ai-agent-app@PROJECT_ID.iam.gserviceaccount.com`, which holds `roles/aiplatform.user`. Terraform creates the SA and binding; `k8s/serviceaccount.yaml` carries the annotation. Nothing to leak, nothing to rotate.
- **Chat UI status bar:** polls `/healthz` and `/version` every 3s. Health dot green/red (red on any non-2xx or timeout), `version:` label, `BUILD_FLAVOR` label (e.g. `stable` vs `canary-broken`), and a `failure_mode:` badge that appears whenever the mode isn't `none`. This is the on-screen rollback narrative.

### FAILURE_MODE (the demo toggle)

Read at request time from the env (in-cluster: `k8s/configmap.yaml`). Unknown values safely degrade to `none`.

| Mode | Behavior | What the demo shows |
|---|---|---|
| `none` | `/healthz` 200, agent normal | Healthy baseline |
| `healthz_500` | `/healthz` returns 500 while `/agent` still works | Liveness probe fails → restart loop → canary declared failed → **auto-rollback** |
| `latency` | `/healthz` sleeps `HEALTHZ_LATENCY_SECONDS` (default 10s); probe timeout is 2s | Slow ≙ dead: probe timeouts trip the same rollback path |
| `crash_on_start` | Process exits non-zero at startup | CrashLoopBackOff; pod never Ready; `progressDeadlineSeconds: 60` marks the rollout Failed fast |
| `bad_agent` | `/healthz` stays 200 (green!) but `/agent` returns garbage (`%%%## AGENT MALFUNCTION ##%%%…`) with **zero** LLM/Vertex calls | Probes can't see AI quality regressions — the Continuous Verification pitch |

Probe math (see `k8s/deployment.yaml`): readiness (`/ready`) marks a bad pod unready in ~13s, liveness (`/healthz`) restarts it in ~20s, and `progressDeadlineSeconds: 60` fails the rollout — demo-fast, deliberately more aggressive than production values.

## Run locally

Tested with Python 3.11. The stub LLM provider is the default — **no GCP account, credentials, or network needed locally.**

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt -r requirements-dev.txt

# Tests (43 pass)
python -m pytest app/tests

# Run the app
uvicorn app.main:app --port 8080
# Chat UI: http://localhost:8080/
```

Env vars (all optional locally):

| Var | Default | Notes |
|---|---|---|
| `FAILURE_MODE` | `none` | `none` \| `healthz_500` \| `crash_on_start` \| `latency` \| `bad_agent` |
| `LLM_PROVIDER` | `stub` | `stub` or `vertex` (vertex needs `GOOGLE_CLOUD_PROJECT` + ADC) |
| `BUILD_FLAVOR` | `dev` | Shown in `/version` and the UI status bar |
| `APP_VERSION` | `0.1.0` | Shown in `/version` |
| `HEALTHZ_LATENCY_SECONDS` | `10` | Sleep for `latency` mode — shrink it for quick local checks |
| `GOOGLE_CLOUD_PROJECT` / `GOOGLE_CLOUD_LOCATION` / `GEMINI_MODEL` | — / `us-central1` / `gemini-2.0-flash` | vertex provider only |

### One curl per failure mode

Env is read per-request, but a running process can't change its env — restart uvicorn with each mode.

```bash
# none — healthy baseline
FAILURE_MODE=none uvicorn app.main:app --port 8080 &
curl -i http://localhost:8080/healthz            # HTTP 200 {"status":"ok",...}
curl -s -X POST http://localhost:8080/agent -H 'Content-Type: application/json' \
  -d '{"prompt":"what is 6*7"}'                  # {"response":"The result is 42.","tool_used":"calculator","provider":"stub"}
kill %1

# healthz_500 — health lies dead while the agent still answers
FAILURE_MODE=healthz_500 uvicorn app.main:app --port 8080 &
curl -i http://localhost:8080/healthz            # HTTP 500 {"status":"unhealthy",...}
curl -s -X POST http://localhost:8080/agent -H 'Content-Type: application/json' \
  -d '{"prompt":"what is 6*7"}'                  # still works
kill %1

# latency — /healthz stalls past the k8s probe timeout (2s); use a short sleep locally
FAILURE_MODE=latency HEALTHZ_LATENCY_SECONDS=3 uvicorn app.main:app --port 8080 &
time curl -s http://localhost:8080/healthz       # returns 200 after ~3s — a 2s probe timeout trips
kill %1

# crash_on_start — process exits non-zero immediately
FAILURE_MODE=crash_on_start uvicorn app.main:app --port 8080; echo "exit code: $?"   # non-zero

# bad_agent — health GREEN, answers garbage, zero LLM calls
FAILURE_MODE=bad_agent uvicorn app.main:app --port 8080 &
curl -i http://localhost:8080/healthz            # HTTP 200 — probes see nothing wrong
curl -s -X POST http://localhost:8080/agent -H 'Content-Type: application/json' \
  -d '{"prompt":"what is 6*7"}'                  # {"response":"%%%## AGENT MALFUNCTION ##%%% ...","provider":"none (bad_agent)"}
kill %1
```

### Container (run on your machine — needs a Docker daemon)

```bash
docker build -t ai-agent-lab .
docker run --rm -p 8080:8080 ai-agent-lab
# The image HEALTHCHECK probes /healthz; run with -e FAILURE_MODE=healthz_500
# and `docker ps` will show the container flip to (unhealthy).
```

## Infrastructure (Terraform → GKE)

> All commands in this section run **on your machine** with `gcloud`, `kubectl`, and Terraform >= 1.5 installed and a GCP project you can bill. Cluster create takes ~5–10 min — stand it up *before* your demo slot.

What `terraform apply` creates: required project APIs (never disabled on destroy), a **zonal** Standard GKE cluster with `deletion_protection = false`, one spot node pool (1–2 × `e2-small`, validation-capped at 2), the `ai-agent-app` GCP service account with `roles/aiplatform.user`, and the Workload Identity binding for `ai-agent/ai-agent-sa`. Optionally (`enable_artifact_registry = true`, default off) an Artifact Registry Docker repo — DockerHub is the primary registry. State is local on purpose; this stack lives for hours.

### Easy path: `scripts/up.sh`

One command runs everything in this section: preflight (terraform/gcloud/kubectl on PATH, `terraform/terraform.tfvars` present, working Application Default Credentials — if not, it tells you to run `gcloud auth application-default login`), `terraform init` + `apply`, `gcloud container clusters get-credentials` from the Terraform outputs, patches the `PROJECT_ID` and image placeholders into a **temp copy** of `k8s/` (the checked-in manifests are never modified — Harness consumes those as-is), applies namespace-first, waits for the rollout (120s, non-fatal) and the LoadBalancer external IP (polls up to ~180s), then prints the demo URL and a `down.sh` cost reminder.

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars   # edit project_id first
DOCKERHUB_USER=<your-dockerhub-user> scripts/up.sh                 # deploys <you>/ai-agent-lab:latest
```

| Flag / env var | Effect |
|---|---|
| `-i, --image <full-ref>` | Exact image to deploy — wins over `DOCKERHUB_USER` |
| `DOCKERHUB_USER=<you>` | Deploy `<you>/ai-agent-lab:latest` |
| `TF_AUTO_APPROVE=1` | Pass `-auto-approve` to `terraform apply` (non-interactive) |
| `-h, --help` | Usage |

If neither `-i/--image` nor `DOCKERHUB_USER` is set, the `DOCKERHUB_USER` image placeholder is left in the Deployment and the pod sits in **ImagePullBackOff** until Harness (or you) deploys a real image — an acceptable state for wiring up the pipeline; the script warns instead of failing.

> The scripts are `bash -n`- and shellcheck-clean but — exactly like the manual commands in this section — have **not** been executed against a live GCP project from the environment that built this repo. First run: watch the output.

### Manual alternative (what the script does under the hood)

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # edit project_id (tfvars is gitignored — never commit it)
terraform init
terraform apply -var-file=terraform.tfvars     # ~5-10 min

# Point kubectl at the cluster (also printed as the get_credentials_command output):
gcloud container clusters get-credentials ai-agent-lab --zone us-central1-a --project <PROJECT_ID>
```

### Patch the manifest placeholders, then deploy

Two files carry a `PROJECT_ID` placeholder and one carries a DockerHub image placeholder:

```bash
cd ..   # repo root
sed -i "s/PROJECT_ID/<PROJECT_ID>/" k8s/serviceaccount.yaml k8s/configmap.yaml
sed -i "s/DOCKERHUB_USER/<your-dockerhub-user>/" k8s/deployment.yaml
# (Harness can override these instead — see Harness prerequisites.)

kubectl apply -f k8s/namespace.yaml && kubectl apply -f k8s/
kubectl -n ai-agent get pods -w                          # wait for Ready
kubectl -n ai-agent get svc ai-agent                     # EXTERNAL-IP = the demo URL (port 80)
```

### Verify Vertex AI access from a pod (Workload Identity, no keys)

The ConfigMap sets `LLM_PROVIDER=vertex` in-cluster, so this runs the real agent loop against Gemini from inside the pod:

```bash
kubectl -n ai-agent exec deploy/ai-agent -- \
  python -c "from app.agent import core; print(core.run_agent('what is 6*7')['response'])"
```

A sensible answer back means the KSA→GCP-SA impersonation and `aiplatform.user` grant are working. (`curl http://<EXTERNAL-IP>/ready` should also report `"llm_provider": "vertex"`.)

> ### ⚠️ `terraform destroy` after EVERY demo session
> This cluster bills by the hour whether or not you're looking at it. The lab has no auto-teardown. When the demo ends, run `scripts/down.sh` (it deletes the LoadBalancer Service first, then destroys) — see [Teardown + costs](#teardown--costs).

## Harness prerequisites

The pipeline itself is configured **by you, in the Harness UI** — there is deliberately no Harness YAML in this repo. What the repo provides for it:

- **Delegate:** install a Harness Kubernetes delegate **into the lab cluster** (Harness UI → install-delegate flow; it must run in-cluster so CD can reach the API server and CI has a build infra).
- **CI test step:**
  ```bash
  pip install -r requirements.txt -r requirements-dev.txt
  python -m pytest app/tests
  ```
- **CI build/push:** `Dockerfile` at repo root, build context = repo root. Push to DockerHub; the deployment references `DOCKERHUB_USER/ai-agent-lab:latest` and expects Harness to supply the image/tag at deploy time (e.g. `<+artifact.image>`).
- **CD manifests:** point the Harness service at the `k8s/` directory. It contains exactly **one Deployment** (`ai-agent`) — Harness K8s Canary manages exactly one workload; never add a second. Probes are tuned to fail a bad canary within seconds (see table above).
- **The failure toggle:** `FAILURE_MODE` in `k8s/configmap.yaml` (alongside `BUILD_FLAVOR`, which drives the visible UI label). Flip it by editing the ConfigMap value or, better for the demo, expose it as a Harness service/pipeline variable that overrides the manifest — same image, healthy or broken purely by config.
- **Rollback:** use the K8s **Canary** deployment strategy; Harness rolls back automatically when the canary workload fails to reach steady state (which the failure modes guarantee).

## Demo script

Prep: cluster up and app deployed (`scripts/up.sh`, or the manual steps in [Infrastructure](#infrastructure-terraform--gke)), app green via Harness, browser open on `http://<EXTERNAL-IP>/`, a second window on the Harness pipeline execution.

1. **Green baseline.** Status bar: green health dot, `version: 0.1.0`, flavor `stable`, no failure badge. Ask the agent `what is 6*7` and `tell me about canary deployments` — real Gemini answers, and point out there is **no API key anywhere** (Workload Identity).
2. **Ship a broken canary.** Set `FAILURE_MODE=healthz_500` (and `BUILD_FLAVOR=canary-broken` so the label change is visible) via your Harness variable override or the ConfigMap, and run the pipeline. Same image, one config value changed.
3. **Watch it fail.** The canary pod's `/healthz` returns 500: liveness kills it within ~20s and it restart-loops; the rollout can't reach steady state (`progressDeadlineSeconds: 60`). If the canary takes traffic you'll see the health dot flick red. `kubectl -n ai-agent get pods -w` shows the restarts if you want the terminal view.
4. **Auto-rollback.** Harness marks the canary phase failed and rolls back without any human action. On screen: health dot settles **green**, flavor label reverts to `stable`, failure badge gone. Chat still answers. That's the headline: *bad deploy detected and reverted automatically.*
5. **The kicker — `bad_agent`.** Redeploy with `FAILURE_MODE=bad_agent` (flavor e.g. `canary-bad-agent`). This canary **passes every probe** — the dot stays green, the rollout succeeds, Harness sees a healthy deployment. Now ask the agent anything: `%%%## AGENT MALFUNCTION ##%%% zxq9!! bleep blorp…`. The service is "healthy" and the product is garbage — and it never even called the LLM.
6. **Land the pitch.** Liveness probes catch dead processes, not dumb answers. AI quality regressions sail straight through health-check-based rollback — that's the gap Harness **Continuous Verification** (verifying real service behavior/metrics during the canary phase, not just probe status) exists to close.
7. Roll back to `FAILURE_MODE=none`, then **tear down** with `scripts/down.sh` (next section).

Variants if you have time: `latency` (slow is the new down — 2s probe timeout vs a 10s handler) and `crash_on_start` (CrashLoopBackOff, the classic).

## Teardown + costs

**Do this at the end of every session** (run on your machine):

```bash
scripts/down.sh                    # TF_AUTO_APPROVE=1 scripts/down.sh for non-interactive
```

`scripts/down.sh` deletes the LoadBalancer Service (`k8s/service.yaml`) **first** — its GCP forwarding rule lives outside Terraform state and can orphan (and keep billing) if the cluster is destroyed underneath it — waits ~20s for GCP to release the rule, runs `terraform destroy` (~5 min; requires the same `terraform/terraform.tfvars` that apply used), and prints the `gcloud` leftover-check commands. It tolerates a cluster that's already gone or an unreachable kubectl context: it skips the Service delete with a note and proceeds to destroy. Same untested-live caveat as `up.sh`.

Manual equivalent:

```bash
# 1. Release the load balancer first — LB Services created outside Terraform
#    can orphan forwarding rules/firewalls that keep billing after destroy:
kubectl delete -f k8s/ --ignore-not-found

# 2. Destroy the cluster and IAM (~5 min):
cd terraform
terraform destroy -var-file=terraform.tfvars
```

If you forget, what keeps billing:

| Left behind | Approx. cost |
|---|---|
| GKE zonal control plane | ~$0.10/hr (~$73/mo) beyond any free-tier credit |
| 1–2 `e2-small` spot nodes + 30 GB pd-standard disks | a few $/day |
| LoadBalancer forwarding rule (`k8s/service.yaml`) | ~$0.025/hr + traffic |
| Artifact Registry images (only if `enable_artifact_registry = true`) | storage $/GB-month — bills even after the cluster is gone (destroy removes the repo and its images) |

Notes: `deletion_protection = false` is set so destroy never wedges; project APIs stay enabled on destroy by design (harmless, no idle cost, faster next apply). Verify nothing lingers with `gcloud container clusters list` and `gcloud compute forwarding-rules list`.
