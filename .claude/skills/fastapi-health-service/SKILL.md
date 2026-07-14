---
name: fastapi-health-service
description: Scaffolds a FastAPI service with /healthz, /ready, /version endpoints and env-var-driven behavior toggles (FAILURE_MODE pattern) for probe-driven Kubernetes apps and rollback demos. Use when building or modifying the FastAPI app's health/version/failure-mode surface.
---

# FastAPI Health Service Pattern

A probe-driven FastAPI app where health behavior is a **config toggle, not a code change** — the same image deploys healthy or broken depending on env vars.

## Core pattern

```python
# config.py
import os
from enum import Enum

class FailureMode(str, Enum):
    NONE = "none"
    HEALTHZ_500 = "healthz_500"
    CRASH_ON_START = "crash_on_start"
    LATENCY = "latency"
    BAD_AGENT = "bad_agent"

def get_failure_mode() -> FailureMode:
    raw = os.getenv("FAILURE_MODE", "none").strip().lower()
    try:
        return FailureMode(raw)
    except ValueError:
        return FailureMode.NONE  # unknown value must never take the app down

APP_VERSION = os.getenv("APP_VERSION", "0.1.0")
BUILD_FLAVOR = os.getenv("BUILD_FLAVOR", "dev")
HEALTHZ_LATENCY_SECONDS = float(os.getenv("HEALTHZ_LATENCY_SECONDS", "10"))
```

```python
# main.py essentials
import asyncio, sys
from fastapi import FastAPI, Response
from . import config

app = FastAPI()

@app.on_event("startup")  # or lifespan context
async def maybe_crash():
    if config.get_failure_mode() == config.FailureMode.CRASH_ON_START:
        print("FAILURE_MODE=crash_on_start: exiting", file=sys.stderr)
        sys.exit(1)

@app.get("/healthz")
async def healthz(response: Response):
    mode = config.get_failure_mode()
    if mode == config.FailureMode.HEALTHZ_500:
        response.status_code = 500
        return {"status": "unhealthy", "failure_mode": mode}
    if mode == config.FailureMode.LATENCY:
        await asyncio.sleep(config.HEALTHZ_LATENCY_SECONDS)  # async sleep — don't block the loop
    return {"status": "ok", "failure_mode": mode}

@app.get("/version")
async def version():
    return {"version": config.APP_VERSION, "build_flavor": config.BUILD_FLAVOR}
```

## Rules of the pattern
- **Read FAILURE_MODE at request time** (or app-factory time), never cache at import — tests monkeypatch env and rebuild the app.
- Unknown FAILURE_MODE values degrade to `none` — a typo in a ConfigMap must not brick the healthy path.
- `/healthz` = liveness (is the process sane), `/ready` = readiness (can it serve: config valid, LLM provider constructed). Keep them separate endpoints even if initially similar — probes point at each independently.
- `latency` mode must use `asyncio.sleep`, and the sleep duration must be env-tunable so tests can shrink it.
- `crash_on_start` exits non-zero from the startup hook so K8s sees CrashLoopBackOff and the pod never becomes ready.
- `/version` must include a human-visible `build_flavor` label — this is how a rollback becomes visible in the UI.
- Use an **app factory** (`create_app()`) so tests can build fresh instances per FAILURE_MODE.
- Static UI: `app.mount("/", StaticFiles(directory=..., html=True))` **after** all API routes are registered, so it doesn't shadow them.
