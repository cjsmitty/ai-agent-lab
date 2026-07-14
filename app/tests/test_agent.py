"""Tests for POST /agent with the stub LLM provider, plus direct
unit tests of the calculator tool. No network, no GCP."""

import pytest

from app.agent import core as agent_core
from app.agent import tools

RESPONSE_KEYS = {"response", "tool_used", "provider"}


# --- /agent endpoint: tool selection + response shape ------------------------

def test_agent_math_prompt_uses_calculator(client):
    resp = client.post("/agent", json={"prompt": "what is 6*7?"})
    assert resp.status_code == 200
    body = resp.json()
    assert set(body) == RESPONSE_KEYS
    assert body["tool_used"] == "calculator"
    assert body["provider"] == "stub"
    assert "42" in body["response"]


def test_agent_math_with_spaces_and_parens(client):
    body = client.post("/agent", json={"prompt": "compute (2 + 3) * 4 please"}).json()
    assert body["tool_used"] == "calculator"
    assert "20" in body["response"]


def test_agent_known_topic_uses_lookup(client):
    body = client.post("/agent", json={"prompt": "tell me about canary deployments"}).json()
    assert body["tool_used"] == "lookup"
    assert body["provider"] == "stub"
    assert body["response"] == tools.FACTS["canary"]


def test_agent_kubernetes_topic_uses_lookup(client):
    body = client.post("/agent", json={"prompt": "What is Kubernetes?"}).json()
    assert body["tool_used"] == "lookup"
    assert body["response"] == tools.FACTS["kubernetes"]


def test_agent_smalltalk_answers_without_tool(client):
    body = client.post("/agent", json={"prompt": "hello there, who are you?"}).json()
    assert body["tool_used"] is None
    assert body["provider"] == "stub"
    assert "stub agent" in body["response"]


def test_agent_division_by_zero_surfaces_tool_error_gracefully(client):
    resp = client.post("/agent", json={"prompt": "what is 1/0"})
    assert resp.status_code == 200  # tool errors are answers, not 5xx
    body = resp.json()
    assert body["tool_used"] == "calculator"
    assert "division by zero" in body["response"]


# --- /agent endpoint: error handling -----------------------------------------

@pytest.mark.parametrize("prompt", ["", "   ", "\n\t"])
def test_agent_empty_prompt_422(client, prompt):
    resp = client.post("/agent", json={"prompt": prompt})
    assert resp.status_code == 422


def test_agent_missing_prompt_field_422(client):
    resp = client.post("/agent", json={})
    assert resp.status_code == 422


def test_agent_provider_failure_returns_502(client, monkeypatch):
    def _boom():
        raise RuntimeError("provider exploded")

    monkeypatch.setattr(agent_core, "get_provider", _boom)
    resp = client.post("/agent", json={"prompt": "what is 2+2"})
    assert resp.status_code == 502
    assert "agent error" in resp.json()["detail"]


# --- calculator tool: direct unit tests --------------------------------------

@pytest.mark.parametrize(
    ("expression", "expected"),
    [
        ("6*7", "42"),
        ("2 + 3 * 4", "14"),
        ("(2 + 3) * 4", "20"),
        ("10 / 4", "2.5"),
        ("10 / 5", "2"),  # integral floats normalize to int
        ("2**10", "1024"),
        ("-5 + 3", "-2"),
        ("7 % 3", "1"),
        ("7 // 2", "3"),
    ],
)
def test_calculator_arithmetic(expression, expected):
    assert tools.calculator(expression) == expected


def test_calculator_division_by_zero():
    assert tools.calculator("1/0") == "calculator error: division by zero"


@pytest.mark.parametrize(
    "expression",
    [
        "__import__('os')",
        "__import__('os').system('id')",
        "open('/etc/passwd')",
        "x + 1",  # names rejected
        "1; import os",
        "[1,2,3]",
    ],
)
def test_calculator_rejects_non_arithmetic(expression):
    result = tools.calculator(expression)
    assert result.startswith("calculator error:")


def test_calculator_empty_and_oversized_input():
    assert tools.calculator("   ") == "calculator error: empty expression"
    assert tools.calculator("1+" * 200 + "1") == "calculator error: expression too long"


def test_calculator_huge_exponent_refused():
    assert "exponent too large" in tools.calculator("9**999")
