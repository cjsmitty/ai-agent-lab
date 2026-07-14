"""FastAPI AI agent service for the Harness canary/rollback demo.

Health behavior is a config toggle (FAILURE_MODE env var), never a code
change — the same image deploys healthy or broken. See app/config.py.
"""

import asyncio
import sys
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI, HTTPException, Response
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

from . import config
from .agent import core as agent_core

STATIC_DIR = Path(__file__).parent / "static"


class AgentRequest(BaseModel):
    prompt: str


def create_app() -> FastAPI:
    """App factory so tests can build fresh instances per FAILURE_MODE."""

    @asynccontextmanager
    async def lifespan(_: FastAPI):
        if config.get_failure_mode() == config.FailureMode.CRASH_ON_START:
            print("FAILURE_MODE=crash_on_start: exiting non-zero", file=sys.stderr)
            sys.exit(1)
        yield

    app = FastAPI(title="ai-agent-lab", lifespan=lifespan)

    @app.get("/healthz")
    async def healthz(response: Response):
        mode = config.get_failure_mode()
        if mode == config.FailureMode.HEALTHZ_500:
            response.status_code = 500
            return {"status": "unhealthy", "failure_mode": mode}
        if mode == config.FailureMode.LATENCY:
            # async sleep — stalls this probe past its timeout without
            # blocking the event loop for other requests
            await asyncio.sleep(config.get_healthz_latency_seconds())
        return {"status": "ok", "failure_mode": mode}

    @app.get("/ready")
    async def ready(response: Response):
        mode = config.get_failure_mode()
        try:
            if mode != config.FailureMode.BAD_AGENT:
                # Constructing the provider validates config (and, for
                # vertex, project/location + SDK availability). No network
                # round-trip — probes must stay fast.
                agent_core.get_provider()
        except Exception as exc:  # config invalid / SDK missing
            response.status_code = 503
            return {"status": "not_ready", "reason": str(exc), "failure_mode": mode}
        return {
            "status": "ready",
            "llm_provider": config.get_llm_provider_name(),
            "failure_mode": mode,
        }

    @app.get("/version")
    async def version():
        return {
            "version": config.get_app_version(),
            "build_flavor": config.get_build_flavor(),
            "failure_mode": config.get_failure_mode(),
        }

    @app.post("/agent")
    async def agent(request: AgentRequest):
        prompt = request.prompt.strip()
        if not prompt:
            raise HTTPException(status_code=422, detail="prompt must not be empty")
        try:
            # run_agent handles FAILURE_MODE=bad_agent internally (garbage
            # response, zero LLM/Vertex calls).
            result = await asyncio.to_thread(agent_core.run_agent, prompt)
        except Exception as exc:
            raise HTTPException(status_code=502, detail=f"agent error: {exc}") from exc
        return result

    # Static chat UI (owned by frontend-builder) — mounted LAST so it never
    # shadows API routes; guarded so the app boots before static/ exists.
    if STATIC_DIR.is_dir():
        app.mount("/", StaticFiles(directory=str(STATIC_DIR), html=True), name="static")

    return app


app = create_app()
