"""Shared fixtures for the ai-agent-lab test suite.

Every test runs with the stub LLM provider (zero Vertex/network calls) and
an explicit FAILURE_MODE baseline of "none". Config is read at request time
by the app, so monkeypatching env vars + building a fresh app via
create_app() is enough for each test to see its own settings.
"""

import warnings

import pytest

# fastapi 0.139 emits a StarletteDeprecationWarning at TestClient import
# time (httpx vs httpx2); irrelevant to this suite, so silence it before
# importing TestClient.
warnings.filterwarnings("ignore", module="fastapi.testclient")

from fastapi.testclient import TestClient  # noqa: E402

from app.main import create_app  # noqa: E402


@pytest.fixture(autouse=True)
def _test_env(monkeypatch):
    """Force the stub provider and a known-good baseline for every test."""
    monkeypatch.setenv("LLM_PROVIDER", "stub")
    monkeypatch.setenv("FAILURE_MODE", "none")


@pytest.fixture
def make_client(monkeypatch):
    """Factory: set env overrides, then build a fresh app + TestClient.

    Usage: client = make_client(FAILURE_MODE="healthz_500")
    """

    def _make(**env: str) -> TestClient:
        for key, value in env.items():
            monkeypatch.setenv(key, str(value))
        return TestClient(create_app())

    return _make


@pytest.fixture
def client(make_client):
    """A TestClient with the default healthy configuration."""
    return make_client()
