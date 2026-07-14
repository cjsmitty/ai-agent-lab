---
name: pinned-python-container
description: Multi-stage Dockerfile best practices for Python services — exact-pinned deps, slim base, venv copy, non-root user, layer caching, and a no-curl HEALTHCHECK. Use when writing or reviewing the Dockerfile or requirements.txt.
---

# Pinned Python Container Pattern

Small, reproducible, non-root Python images with a working healthcheck.

## The shape

```dockerfile
# ---- builder ----
FROM python:3.12-slim AS builder
WORKDIR /build
RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# ---- runtime ----
FROM python:3.12-slim
RUN useradd --create-home --uid 1000 appuser
COPY --from=builder /opt/venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH" \
    PYTHONUNBUFFERED=1 \
    PORT=8080
WORKDIR /srv
COPY app/ ./app/
USER appuser
EXPOSE 8080
HEALTHCHECK --interval=10s --timeout=3s --retries=3 \
  CMD python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8080/healthz', timeout=2).status==200 else 1)"
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8080"]
```

## Rules
- **Pin everything exactly** (`fastapi==x.y.z`) in requirements.txt — reproducible builds; CI and demo build identical images. Match the local dev Python minor version to the image.
- **Layer order = cache order:** `COPY requirements.txt` + `pip install` BEFORE `COPY app/` — code edits don't re-resolve deps.
- **venv copy between stages** keeps build toolchain out of the runtime image; keep both stages on the same base image so the venv's interpreter path holds.
- **Non-root** (`USER appuser`, uid ≥ 1000) — also what GKE/PSS expects. Bind a port ≥ 1024.
- **HEALTHCHECK without curl:** slim images have no curl/wget; use the python urllib one-liner. Note: exec-probe cost is trivial here, and K8s uses its own httpGet probes — the Docker HEALTHCHECK is for local `docker run` verification.
- `.dockerignore`: `.git`, `terraform/`, `k8s/`, `.claude/`, `__pycache__`, `.venv`, tests caches — smaller context, fewer cache busts.
- Config via env only (`FAILURE_MODE`, `BUILD_FLAVOR`, `GOOGLE_CLOUD_*`) — no secrets or keys baked into the image, ever. Vertex auth is ambient (Workload Identity/ADC), so there is no key to leak.
- Verify: build, run, curl `/healthz` and `/`, then run with `-e FAILURE_MODE=healthz_500` and watch `docker ps` flip to `(unhealthy)`.
