"""Happy-path tests for /healthz, /ready and /version."""


def test_healthz_ok(client):
    resp = client.get("/healthz")
    assert resp.status_code == 200
    body = resp.json()
    assert body["status"] == "ok"
    assert body["failure_mode"] == "none"


def test_ready_ok_with_stub_provider(client):
    resp = client.get("/ready")
    assert resp.status_code == 200
    body = resp.json()
    assert body["status"] == "ready"
    assert body["llm_provider"] == "stub"
    assert body["failure_mode"] == "none"


def test_version_defaults(client):
    resp = client.get("/version")
    assert resp.status_code == 200
    body = resp.json()
    assert set(body) == {"version", "build_flavor", "failure_mode"}
    assert body["version"]  # non-empty
    assert body["build_flavor"]  # BUILD_FLAVOR always present, non-empty
    assert body["failure_mode"] == "none"


def test_version_reflects_env(make_client):
    client = make_client(APP_VERSION="9.9.9", BUILD_FLAVOR="canary-blue")
    body = client.get("/version").json()
    assert body["version"] == "9.9.9"
    assert body["build_flavor"] == "canary-blue"
