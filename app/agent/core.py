"""Minimal tool-using agent loop with a swappable LLM provider.

Providers implement a single `decide(prompt)` step that returns either a
tool call or a final answer, using a tiny line protocol:

    TOOL: <tool_name> | <tool_input>
    ANSWER: <text>

The StubProvider is fully deterministic and network-free (default for local
dev and tests). The VertexProvider talks to Gemini on Vertex AI via the
google-genai SDK with ambient GCP credentials — no API keys.
"""

import re
from dataclasses import dataclass
from typing import Optional

from .. import config
from . import tools


@dataclass
class Decision:
    """One provider step: either a tool call or a final answer."""

    answer: Optional[str] = None
    tool_name: Optional[str] = None
    tool_input: Optional[str] = None


def _parse_decision(text: str) -> Decision:
    text = text.strip()
    match = re.match(r"^TOOL:\s*(\w+)\s*\|\s*(.+)$", text, re.DOTALL)
    if match:
        return Decision(tool_name=match.group(1).lower(), tool_input=match.group(2).strip())
    if text.upper().startswith("ANSWER:"):
        return Decision(answer=text[len("ANSWER:"):].strip())
    return Decision(answer=text)  # model went off-script — treat as final answer


class LLMProvider:
    """Provider interface: one decision step, optionally after a tool run."""

    name = "base"

    def decide(self, prompt: str, tool_name: Optional[str] = None,
               tool_output: Optional[str] = None) -> Decision:
        raise NotImplementedError


class StubProvider(LLMProvider):
    """Deterministic, network-free provider for local dev and tests.

    Routes arithmetic-looking prompts to the calculator, known topics to
    the lookup tool, and answers everything else with a canned reply.
    """

    name = "stub"

    _MATH_RE = re.compile(r"([-+(]*\d[\d\s.+\-*/%()]*\d|\d)")

    def decide(self, prompt: str, tool_name: Optional[str] = None,
               tool_output: Optional[str] = None) -> Decision:
        if tool_name is not None:
            if tool_name == "calculator":
                return Decision(answer=f"The result is {tool_output}.")
            return Decision(answer=tool_output or "")

        lowered = prompt.lower()

        # Arithmetic? Extract the longest math-looking span with an operator.
        candidates = [c.strip() for c in self._MATH_RE.findall(prompt)]
        candidates = [c for c in candidates if re.search(r"[-+*/%]", c) and re.search(r"\d\s*[-+*/%]\s*[-(]*\d", c)]
        if candidates:
            expr = max(candidates, key=len)
            return Decision(tool_name="calculator", tool_input=expr)

        # Known topic? Use the lookup tool.
        for topic in tools.FACTS:
            if topic in lowered:
                return Decision(tool_name="lookup", tool_input=topic)

        return Decision(answer=(
            "I'm the stub agent for the Harness AI Agent Lab. "
            "Ask me arithmetic (e.g. 'what is 6*7') or about: "
            + ", ".join(sorted(tools.FACTS)) + "."
        ))


class VertexProvider(LLMProvider):
    """Gemini on Vertex AI via google-genai. Ambient ADC / Workload Identity
    credentials only — no API keys. Imported lazily so the app runs without
    the google-genai package installed in stub mode."""

    name = "vertex"

    _SYSTEM = (
        "You are a helpful assistant with two tools.\n"
        "To use a tool, reply with EXACTLY one line and nothing else:\n"
        "  TOOL: calculator | <arithmetic expression>\n"
        "  TOOL: lookup | <topic>\n"
        "The lookup tool knows about: " + ", ".join(sorted(tools.FACTS)) + ".\n"
        "Otherwise, or once you have a tool result, reply with:\n"
        "  ANSWER: <your final answer>"
    )

    def __init__(self) -> None:
        from google import genai  # lazy: only needed when LLM_PROVIDER=vertex

        project = config.get_gcp_project()
        if not project:
            raise RuntimeError("GOOGLE_CLOUD_PROJECT is required for LLM_PROVIDER=vertex")
        self._client = genai.Client(
            vertexai=True,
            project=project,
            location=config.get_gcp_location(),
        )
        self._model = config.get_gemini_model()

    def _generate(self, contents: str) -> str:
        from google.genai import types  # lazy

        response = self._client.models.generate_content(
            model=self._model,
            contents=contents,
            config=types.GenerateContentConfig(system_instruction=self._SYSTEM),
        )
        return response.text or ""

    def decide(self, prompt: str, tool_name: Optional[str] = None,
               tool_output: Optional[str] = None) -> Decision:
        if tool_name is None:
            return _parse_decision(self._generate(prompt))
        followup = (
            f"User asked: {prompt}\n"
            f"Tool '{tool_name}' returned: {tool_output}\n"
            "Give the final answer now."
        )
        return _parse_decision(self._generate(followup))


def get_provider() -> LLMProvider:
    """Build the configured provider. Read at request time so env flips
    (ConfigMap changes) take effect without a code change."""
    if config.get_llm_provider_name() == "vertex":
        return VertexProvider()
    return StubProvider()


GARBAGE_RESPONSE = (
    "%%%## AGENT MALFUNCTION ##%%% zxq9!! bleep blorp 0xDEADBEEF "
    "response tensor unaligned :: garbage garbage garbage ::"
)


def run_agent(prompt: str) -> dict:
    """One-shot agent loop: decide -> (maybe) run one tool -> final answer.

    FAILURE_MODE=bad_agent short-circuits here with garbage output and
    never constructs a provider — guaranteed zero Vertex calls.
    """
    if config.get_failure_mode() == config.FailureMode.BAD_AGENT:
        return {
            "response": GARBAGE_RESPONSE,
            "tool_used": None,
            "provider": "none (bad_agent)",
        }

    provider = get_provider()
    decision = provider.decide(prompt)

    tool_used = None
    if decision.tool_name is not None:
        tool_used = decision.tool_name
        tool_fn = tools.TOOLS.get(decision.tool_name)
        if tool_fn is None:
            tool_output = f"error: unknown tool '{decision.tool_name}'"
        else:
            tool_output = tool_fn(decision.tool_input or "")
        decision = provider.decide(prompt, tool_name=tool_used, tool_output=tool_output)

    return {
        "response": decision.answer or "",
        "tool_used": tool_used,
        "provider": provider.name,
    }
