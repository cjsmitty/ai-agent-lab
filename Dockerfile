# Multi-stage build per .claude/skills/pinned-python-container.
# Base is python:3.11-slim to match the local dev venv (Python 3.11.x) —
# identical interpreter minor version for dev, CI, and the deployed image.

# ---- builder: resolve and install pinned deps into a venv ----
FROM python:3.11-slim AS builder
WORKDIR /build
RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"
# requirements before source: code edits never bust the dependency layer.
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# ---- runtime: venv + app source only, non-root ----
FROM python:3.11-slim
RUN useradd --create-home --uid 1000 appuser
COPY --from=builder /opt/venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH" \
    PYTHONUNBUFFERED=1 \
    PORT=8080
WORKDIR /srv
COPY app/ ./app/
USER appuser

# All runtime config is env-driven (FAILURE_MODE, BUILD_FLAVOR, LLM_PROVIDER,
# GOOGLE_CLOUD_PROJECT/LOCATION, GEMINI_MODEL, APP_VERSION) — no secrets baked
# in; Vertex auth is ambient via Workload Identity/ADC.
EXPOSE 8080

# Local docker-run healthcheck (K8s uses its own httpGet probes). slim has no
# curl, so probe /healthz with stdlib urllib.
HEALTHCHECK --interval=10s --timeout=3s --retries=3 \
  CMD python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8080/healthz', timeout=2).status==200 else 1)"

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8080"]
