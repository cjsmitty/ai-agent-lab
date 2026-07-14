"""Demo-critical suite: prove every FAILURE_MODE behaves as specified.

The same image deploys healthy or broken purely via the FAILURE_MODE env
var — these tests are the contract the Harness canary/rollback demo
depends on.
"""

import asyncio
import time

import pytest

from app.agent.core import GARBAGE_RESPONSE
from app.main import create_app


# --- none ---------------------------------------------------------------------

def test_none_healthz_200(make_client):
    client = make_client(FAILURE_MODE="none")
    resp = client.get("/healthz")
    assert resp.status_code == 200
    assert resp.json() == {"status": "ok", "failure_mode": "none"}


def test_unknown_failure_mode_degrades_to_none(make_client):
    """A ConfigMap typo must never take the healthy path down."""
    client = make_client(FAILURE_MODE="definitely_not_a_mode")
    resp = client.get("/healthz")
    assert resp.status_code == 200
    assert resp.json()["failure_mode"] == "none"
    assert client.post("/agent", json={"prompt": "what is 2+2"}).status_code == 200


# --- healthz_500 ----------------------------------------------------------------

def test_healthz_500_fails_liveness(make_client):
    client = make_client(FAILURE_MODE="healthz_500")
    resp = client.get("/healthz")
    assert resp.status_code == 500
    assert resp.json()["status"] == "unhealthy"


def test_healthz_500_leaves_agent_unaffected(make_client):
    client = make_client(FAILURE_MODE="healthz_500")
    resp = client.post("/agent", json={"prompt": "what is 6*7"})
    assert resp.status_code == 200
    body = resp.json()
    assert body["tool_used"] == "calculator"
    assert "42" in body["response"]


# --- crash_on_start -------------------------------------------------------------

def test_crash_on_start_exits_nonzero(monkeypatch):
    """The lifespan startup hook must raise SystemExit(1).

    Tested by driving the lifespan context directly: TestClient's anyio
    portal mangles SystemExit into a CancelledError, so the hook itself
    is the reliable (and per-spec sufficient) thing to assert on.
    """
    monkeypatch.setenv("FAILURE_MODE", "crash_on_start")
    app = create_app()

    async def enter_lifespan():
        async with app.router.lifespan_context(app):
            pass  # pragma: no cover — startup must exit before yielding

    with pytest.raises(SystemExit) as excinfo:
        asyncio.run(enter_lifespan())
    assert excinfo.value.code == 1


def test_no_crash_when_mode_is_none(make_client):
    """Sanity check: the lifespan hook is a no-op for FAILURE_MODE=none."""
    client = make_client(FAILURE_MODE="none")
    with client:  # runs the lifespan — must not raise
        assert client.get("/healthz").status_code == 200


# --- latency --------------------------------------------------------------------

def test_latency_delays_healthz(make_client):
    """/healthz must stall for HEALTHZ_LATENCY_SECONDS (shrunk here so the
    suite stays fast; in the demo the ~10s default blows the probe timeout)."""
    delay = 0.2
    client = make_client(FAILURE_MODE="latency", HEALTHZ_LATENCY_SECONDS=str(delay))
    start = time.perf_counter()
    resp = client.get("/healthz")
    elapsed = time.perf_counter() - start
    assert resp.status_code == 200  # slow, not erroring — the probe timeout kills it
    assert elapsed >= delay
    assert elapsed < 5  # sanity: the shrunk sleep was honored, not the 10s default


def test_latency_does_not_delay_other_endpoints(make_client):
    client = make_client(FAILURE_MODE="latency", HEALTHZ_LATENCY_SECONDS="30")
    start = time.perf_counter()
    resp = client.get("/version")
    elapsed = time.perf_counter() - start
    assert resp.status_code == 200
    assert elapsed < 2  # only /healthz sleeps


# --- bad_agent --------------------------------------------------------------------

def test_bad_agent_healthz_green_but_agent_garbage(make_client):
    """BOTH halves of the 'liveness probes miss AI quality regressions'
    story: the pod looks perfectly healthy while /agent spews garbage."""
    client = make_client(FAILURE_MODE="bad_agent")

    # Half 1: liveness stays green — a canary keyed on /healthz passes.
    health = client.get("/healthz")
    assert health.status_code == 200
    assert health.json()["status"] == "ok"

    # Half 2: the agent is garbage — users see a broken AI product.
    resp = client.post("/agent", json={"prompt": "what is 6*7"})
    assert resp.status_code == 200
    body = resp.json()
    assert body["response"] == GARBAGE_RESPONSE
    assert body["tool_used"] is None
    assert body["provider"] == "none (bad_agent)"
    assert "42" not in body["response"]  # the correct answer never appears


def test_bad_agent_never_constructs_a_provider(make_client, monkeypatch):
    """bad_agent short-circuits before provider construction — guaranteed
    zero Vertex/network calls even if the provider is misconfigured."""
    from app.agent import core as agent_core

    def _boom():
        raise AssertionError("get_provider must not be called in bad_agent mode")

    monkeypatch.setattr(agent_core, "get_provider", _boom)
    client = make_client(FAILURE_MODE="bad_agent")
    resp = client.post("/agent", json={"prompt": "anything"})
    assert resp.status_code == 200
    assert resp.json()["response"] == GARBAGE_RESPONSE
