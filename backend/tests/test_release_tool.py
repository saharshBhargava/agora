"""The release tool (.github/scripts/render_deploy.py) against a simulated Render API, so its control flow is
proven before it touches production: deploy, failed build, smoke failure -> automatic rollback, supersede."""

import importlib.util
import json
from pathlib import Path
from types import SimpleNamespace

import pytest

SCRIPT = Path(__file__).resolve().parents[2] / ".github" / "scripts" / "render_deploy.py"


@pytest.fixture
def tool(monkeypatch):
    spec = importlib.util.spec_from_file_location("render_deploy", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    monkeypatch.setenv("RENDER_API_KEY", "rnd_test")
    monkeypatch.setenv("RENDER_SERVICE_ID", "srv-test")
    monkeypatch.setenv("AGORA_API_URL", "https://api.example")
    for name in ("GITHUB_ACTIONS", "GITHUB_STEP_SUMMARY", "GITHUB_OUTPUT"):  # CI sets these
        monkeypatch.delenv(name, raising=False)
    monkeypatch.delenv("AGORA_DEMO_PASSWORD", raising=False)
    monkeypatch.setattr(module.time, "sleep", lambda _: None)
    return module


class FakeRender:
    """Just enough of Render: deploys go through scripted states; the API serves whatever is live."""

    def __init__(self, live_commit="old", outcome="live", healthy=True, auto_deploy="checksPass"):
        self.deploys = [{"id": "dep-old", "status": "live", "commit": {"id": live_commit}, "trigger": "new_commit"}]
        self.outcome, self.healthy, self.auto_deploy = outcome, healthy, auto_deploy
        self.calls: list[tuple[str, str]] = []

    @property
    def live_commit(self):
        return next(d["commit"]["id"] for d in self.deploys if d["status"] == "live")

    def http(self, method, url, *, body=None, headers=None, timeout=30, retries=3):
        self.calls.append((method, url.split("?")[0]))
        if url.startswith("https://api.render.com/v1"):
            return self.render(method, url.removeprefix("https://api.render.com/v1"), body)
        return self.api(url.removeprefix("https://api.example"))

    def render(self, method, path, body):
        if path == "/services/srv-test" and method == "GET":
            return 200, {"id": "srv-test", "autoDeployTrigger": self.auto_deploy, "ownerId": "tea-1"}
        if path == "/services/srv-test" and method == "PATCH":
            self.auto_deploy = body.get("autoDeployTrigger", "off")
            return 200, {}
        if path.startswith("/services/srv-test/deploys") and method == "GET":
            if path.count("/") == 3:
                return 200, [{"deploy": d, "cursor": d["id"]} for d in self.deploys]
            return 200, next(d for d in self.deploys if d["id"] == path.rsplit("/", 1)[1])
        if path == "/services/srv-test/deploys" and method == "POST":
            return 201, self._start("dep-new", body["commitId"], self.outcome)
        if path == "/services/srv-test/rollback":
            target = next(d for d in self.deploys if d["id"] == body["deployId"])
            self.healthy = True
            return 201, self._start("dep-rollback", target["commit"]["id"], "live")
        if path.startswith("/logs"):
            return 200, {"logs": [{"message": "ERROR: column \"x\" does not exist"}, {"message": "GET /v1/me 200"}]}
        raise AssertionError(f"unexpected Render call {method} {path}")

    def _start(self, deploy_id, commit, outcome):
        deploy = {"id": deploy_id, "status": outcome, "commit": {"id": commit}, "trigger": "api"}
        if outcome == "live":
            for d in self.deploys:
                if d["status"] == "live":
                    d["status"] = "deactivated"
        self.deploys.insert(0, deploy)
        return deploy

    def api(self, path):
        if path == "/readyz":
            return 200, {"ok": True, "commit": self.live_commit, "migrations": {"pending": []}}
        if path == "/openapi.json":
            return 200, {"paths": {p: {} for p in CORE}}
        if path == "/v1/me":
            return (401, None) if self.healthy else (500, None)
        raise AssertionError(path)


CORE = []


def run(tool, fake, monkeypatch, commit="new", **flags):
    CORE[:] = tool.CORE_PATHS
    monkeypatch.setattr(tool, "http", fake.http)
    args = SimpleNamespace(commit=commit, auto_rollback=flags.get("auto_rollback", True), paths=flags.get("paths", []))
    return tool.cmd_deploy(args)


def test_successful_release_turns_off_render_autodeploy(tool, monkeypatch):
    fake = FakeRender()
    assert run(tool, fake, monkeypatch) == 0
    assert fake.live_commit == "new" and fake.auto_deploy == "off"


def test_failed_build_keeps_previous_release_and_goes_red(tool, monkeypatch, capsys):
    fake = FakeRender(outcome="build_failed")
    assert run(tool, fake, monkeypatch) == 1
    out = capsys.readouterr().out
    assert fake.live_commit == "old" and "stayed on old" in out and "is healthy" in out
    assert 'column "x" does not exist' in out and "GET /v1/me 200" not in out  # only error lines are shown


def test_live_but_broken_release_is_rolled_back(tool, monkeypatch, capsys):
    fake = FakeRender(healthy=False)
    assert run(tool, fake, monkeypatch) == 1
    assert fake.live_commit == "old"
    assert ("POST", "https://api.render.com/v1/services/srv-test/rollback") in fake.calls
    assert "rolled back" in capsys.readouterr().out.lower()


def test_no_rollback_without_the_flag(tool, monkeypatch):
    fake = FakeRender(healthy=False)
    assert run(tool, fake, monkeypatch, auto_rollback=False) == 1
    assert fake.live_commit == "new"


def test_already_live_commit_only_verifies(tool, monkeypatch):
    fake = FakeRender(live_commit="new")
    assert run(tool, fake, monkeypatch) == 0
    assert not any(method == "POST" for method, _ in fake.calls)


def test_superseded_release_is_not_a_failure(tool, monkeypatch):
    fake = FakeRender(outcome="deactivated")
    assert run(tool, fake, monkeypatch) == 0


def test_unchanged_backend_skips_the_build(tool, monkeypatch):
    fake = FakeRender()
    monkeypatch.setattr(tool, "_unchanged", lambda old, new, paths: True)
    assert run(tool, fake, monkeypatch, paths=["backend"]) == 0
    assert fake.live_commit == "old" and not any(m == "POST" for m, _ in fake.calls)


def test_smoke_reports_wrong_commit_and_pending_migrations(tool, monkeypatch):
    responses = {"/readyz": (200, {"commit": "aaaa", "migrations": {"pending": ["0099_x.sql"]}}),
                 "/openapi.json": (200, {"paths": {}}), "/v1/me": (200, {})}
    monkeypatch.setattr(tool, "http", lambda m, url, **k: responses[url.removeprefix("https://api.example")])
    failures = tool.smoke("https://api.example", "bbbb", wake_timeout_s=0)
    text = json.dumps(failures)
    assert "expected bbbb" in text and "0099_x.sql" in text and "routes missing" in text and "expected 401" in text
