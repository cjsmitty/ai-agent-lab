# Harness AI Agent Lab

AI Python agentic app (FastAPI + Gemini on Vertex AI) deployed to GKE via a Harness CI/CD canary pipeline, with a **deliberate, env-var-toggleable failure mechanism** (`FAILURE_MODE`) so a canary fails its health check and Harness auto-rolls-back on demand. Infra is ephemeral Terraform on GCP.

## STANDING RULE: delegate ALL implementation work

**ALL implementation work MUST be delegated to the matching subagent (`.claude/agents/`). Never write code, manifests, Terraform, Dockerfiles, or docs directly in the main thread.** The main thread orchestrates: it picks the right subagent, announces it, passes context, and reviews results. One exception: trivial mechanical fixes explicitly requested by the user (e.g. a typo) may be done inline.

| Domain | Subagent |
|---|---|
| `app/` Python service (excl. `static/`, `tests/`) | `app-builder` |
| `app/static/` chat UI | `frontend-builder` |
| `app/tests/` pytest suite | `test-writer` |
| `Dockerfile`, `requirements.txt`, `.dockerignore` | `container-builder` |
| `k8s/` manifests | `k8s-manifester` |
| `terraform/` GCP infra | `terraform-gcp` |
| `README.md` / docs / demo script | `demo-docs` |

The Harness CI/CD pipeline is configured **by the user, manually, in the Harness UI** — no subagent, no skill, and no Harness YAML in this repo. Claude's job is only to make the repo Harness-ready: green pytest suite, buildable image, and `k8s/` manifests with a single Deployment and fast-failing probes.

Each subagent must read its matching skill in `.claude/skills/` before implementing.

## Architecture summary

- **App:** FastAPI service. `GET /healthz` (liveness — the rollback trigger point), `GET /ready` (readiness), `POST /agent` (simple tool-using agent: calculator + lookup), `GET /version` (version + `BUILD_FLAVOR`). Static chat UI served from `app/static/` mounted at `/`.
- **Failure mechanism:** env var `FAILURE_MODE` — `none` | `healthz_500` | `crash_on_start` | `latency` | `bad_agent`. Same image, flipped by config (ConfigMap / Harness service variable), deploys healthy or broken. `bad_agent` keeps `/healthz` green while `/agent` returns garbage (LLM call stubbed, zero Vertex calls) — the "liveness probes miss AI quality regressions" story.
- **LLM:** Gemini Flash via Vertex AI (`google-genai` SDK, `vertexai=True`). Auth via **Workload Identity** — KSA bound to a GCP SA holding `roles/aiplatform.user`. **No LLM API keys anywhere.** Stub provider for local dev/tests.
- **Frontend:** vanilla HTML/CSS/JS chat + status bar polling `/version` and `/healthz` every few seconds — health dot and flavor label make failure and rollback visible on screen.
- **Infra:** Terraform — zonal Standard GKE, 1–2 e2-small spot nodes, APIs (container, compute, artifactregistry, aiplatform), Workload Identity, clean `apply`/`destroy`. Destroy after every demo session.
- **Pipeline (user-managed in the Harness UI, never in this repo):** CI (pytest → docker build → push DockerHub) → CD K8s Canary with automated rollback on failed canary health. Repo constraint that matters: keep `k8s/` to a **single Deployment** — Harness canary manages exactly one workload.

## Shared naming conventions (must stay in sync)

- K8s namespace: `ai-agent` · KSA name: `ai-agent-sa` · GCP SA: `ai-agent-app` — the Workload Identity binding in `terraform/` and the KSA annotation in `k8s/` both use these.
- Container port: `8080` · probes: readiness→`/ready`, liveness→`/healthz`.

## Build order

1. `app-builder` + `test-writer` — local service with all failure modes + green tests
2. `frontend-builder` — chat UI + status bar against local service
3. `container-builder` — image builds/runs locally, healthcheck works
4. `terraform-gcp` — GKE up and down cleanly
5. `k8s-manifester` — manual kubectl deploy; probes and failure modes behave
6. *(user, in the Harness UI)* — pipeline wired; canary + rollback proven
7. `demo-docs` — README + demo script finalized

## Repo boundaries

- Harness pipeline/service/environment/template YAML is **NOT checked into this repo** — it lives in the Harness platform; exported copies go to the user's playback doc only.
- No real `terraform.tfvars`, kubeconfigs, or credentials in git — examples only.
