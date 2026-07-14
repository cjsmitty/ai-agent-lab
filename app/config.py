"""Environment-driven configuration for the AI agent service.

All toggles are read at request time (not cached at import) so tests can
monkeypatch env vars and the same container image can be flipped between
healthy and broken purely via config.
"""

import os
from enum import Enum


class FailureMode(str, Enum):
    NONE = "none"
    HEALTHZ_500 = "healthz_500"
    CRASH_ON_START = "crash_on_start"
    LATENCY = "latency"
    BAD_AGENT = "bad_agent"


def get_failure_mode() -> FailureMode:
    """Read FAILURE_MODE from env. Unknown values degrade to NONE —
    a typo in a ConfigMap must never take the healthy path down."""
    raw = os.getenv("FAILURE_MODE", "none").strip().lower()
    try:
        return FailureMode(raw)
    except ValueError:
        return FailureMode.NONE


def get_app_version() -> str:
    return os.getenv("APP_VERSION", "0.1.0")


def get_build_flavor() -> str:
    return os.getenv("BUILD_FLAVOR", "dev")


def get_healthz_latency_seconds() -> float:
    """Sleep duration for FAILURE_MODE=latency. Env-tunable so tests
    and local verification can shrink it below the default ~10s."""
    try:
        return float(os.getenv("HEALTHZ_LATENCY_SECONDS", "10"))
    except ValueError:
        return 10.0


def get_llm_provider_name() -> str:
    """'stub' (default — local dev needs no GCP) or 'vertex'."""
    raw = os.getenv("LLM_PROVIDER", "stub").strip().lower()
    return raw if raw in ("stub", "vertex") else "stub"


def get_gcp_project() -> str:
    return os.getenv("GOOGLE_CLOUD_PROJECT", "")


def get_gcp_location() -> str:
    return os.getenv("GOOGLE_CLOUD_LOCATION", "us-central1")


def get_gemini_model() -> str:
    return os.getenv("GEMINI_MODEL", "gemini-2.0-flash")
