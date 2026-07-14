"""Tools available to the agent: a safe calculator and a canned lookup."""

import ast
import operator

# --- calculator ------------------------------------------------------------

_BIN_OPS = {
    ast.Add: operator.add,
    ast.Sub: operator.sub,
    ast.Mult: operator.mul,
    ast.Div: operator.truediv,
    ast.FloorDiv: operator.floordiv,
    ast.Mod: operator.mod,
    ast.Pow: operator.pow,
}

_UNARY_OPS = {
    ast.UAdd: operator.pos,
    ast.USub: operator.neg,
}


def _eval_node(node: ast.AST) -> float:
    if isinstance(node, ast.Expression):
        return _eval_node(node.body)
    if isinstance(node, ast.Constant) and isinstance(node.value, (int, float)):
        return node.value
    if isinstance(node, ast.BinOp) and type(node.op) in _BIN_OPS:
        left = _eval_node(node.left)
        right = _eval_node(node.right)
        if isinstance(node.op, ast.Pow) and abs(right) > 100:
            raise ValueError("exponent too large")
        return _BIN_OPS[type(node.op)](left, right)
    if isinstance(node, ast.UnaryOp) and type(node.op) in _UNARY_OPS:
        return _UNARY_OPS[type(node.op)](_eval_node(node.operand))
    raise ValueError(f"unsupported expression element: {type(node).__name__}")


def calculator(expression: str) -> str:
    """Safely evaluate a basic arithmetic expression (+ - * / // % ** and
    parentheses). AST-based — no eval(), no names, no calls."""
    expression = expression.strip()
    if not expression:
        return "calculator error: empty expression"
    if len(expression) > 200:
        return "calculator error: expression too long"
    try:
        tree = ast.parse(expression, mode="eval")
        result = _eval_node(tree)
    except ZeroDivisionError:
        return "calculator error: division by zero"
    except (ValueError, SyntaxError) as exc:
        return f"calculator error: {exc}"
    if isinstance(result, float) and result.is_integer():
        result = int(result)
    return str(result)


# --- canned lookup ----------------------------------------------------------

FACTS = {
    "harness": "Harness is a CI/CD platform with automated canary deployments and rollbacks.",
    "canary": "A canary deployment shifts a small slice of traffic to a new version; if health checks fail, it rolls back automatically.",
    "kubernetes": "Kubernetes is a container orchestration platform; this app runs on GKE.",
    "gke": "GKE (Google Kubernetes Engine) is Google Cloud's managed Kubernetes service.",
    "gemini": "Gemini is Google's family of LLMs, served here via Vertex AI.",
    "vertex": "Vertex AI is Google Cloud's managed ML platform hosting the Gemini models.",
    "fastapi": "FastAPI is a modern async Python web framework; it powers this service.",
    "rollback": "A rollback reverts a deployment to the previous known-good version, triggered here by failing /healthz probes.",
    "terraform": "Terraform provisions the ephemeral GCP infrastructure (GKE cluster, Workload Identity) for this lab.",
}


def lookup(topic: str) -> str:
    """Return a canned fact for a known topic, or a miss message."""
    key = topic.strip().lower()
    if key in FACTS:
        return FACTS[key]
    for name, fact in FACTS.items():
        if name in key:
            return fact
    return f"no canned fact found for '{topic}'"


TOOLS = {
    "calculator": calculator,
    "lookup": lookup,
}
