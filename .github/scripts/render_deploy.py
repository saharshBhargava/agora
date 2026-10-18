"""Production release tool for the Render-hosted API. Standard library only, so any CI runner can use it.

    python .github/scripts/render_deploy.py status
    python .github/scripts/render_deploy.py deploy --commit <sha> [--auto-rollback]
    python .github/scripts/render_deploy.py rollback [--to-commit <sha> | --to-deploy <dep-id>]
    python .github/scripts/render_deploy.py restart
    python .github/scripts/render_deploy.py smoke --base-url <url> [--expect-commit <sha>]

Environment:
    RENDER_API_KEY      Render API key (secret). Needed for everything except `smoke`.
    RENDER_SERVICE_ID   e.g. srv-dba2ram1egvs739549ug
    AGORA_API_URL       public API origin, e.g. https://agora-api-yq3m.onrender.com
    AGORA_DEMO_PASSWORD optional secret: adds read-only signed-in checks against the demo account

Every check is read-only, so smoke runs never change production data. Output goes to the log, to
GitHub annotations, and to the job summary.
"""

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import UTC, datetime, timedelta

API = "https://api.render.com/v1"
TERMINAL_OK = {"live"}
TERMINAL_BAD = {"build_failed", "update_failed", "canceled", "pre_deploy_failed"}
SUPERSEDED = {"deactivated"}
CORE_PATHS = ["/v1/me", "/v1/inventory", "/v1/scans", "/v1/merchants", "/v1/wishlist", "/v1/lists",
              "/v1/forecasts/runouts", "/v1/agent/intents", "/v1/dev/login", "/v1/demo/profile"]


# ---------------------------------------------------------------- output helpers

def log(message: str) -> None:
    print(message, flush=True)


def annotate(level: str, message: str) -> None:
    print(f"::{level}::{message}", flush=True) if os.environ.get("GITHUB_ACTIONS") else log(f"{level}: {message}")


def summary(markdown: str) -> None:
    path = os.environ.get("GITHUB_STEP_SUMMARY")
    if path:
        with open(path, "a", encoding="utf-8") as f:
            f.write(markdown + "\n")
    else:
        log(markdown)


def output(name: str, value: str) -> None:
    path = os.environ.get("GITHUB_OUTPUT")
    if path:
        with open(path, "a", encoding="utf-8") as f:
            f.write(f"{name}={value}\n")


def mask(value: str) -> None:
    if value and os.environ.get("GITHUB_ACTIONS"):
        print(f"::add-mask::{value}", flush=True)


# ---------------------------------------------------------------- HTTP

def http(method: str, url: str, *, body: dict | None = None, headers: dict | None = None,
         timeout: float = 30, retries: int = 3) -> tuple[int, dict | list | str | None]:
    data = json.dumps(body).encode() if body is not None else None
    request_headers = {"Accept": "application/json", "User-Agent": "agora-deploy", **(headers or {})}
    if data is not None:
        request_headers["Content-Type"] = "application/json"
    for attempt in range(retries + 1):
        request = urllib.request.Request(url, data=data, method=method, headers=request_headers)
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:  # noqa: S310 - fixed https hosts
                return response.status, _decode(response.read())
        except urllib.error.HTTPError as error:
            if error.code in (429, 502, 503, 504) and attempt < retries:
                time.sleep(min(60, 5 * 2 ** attempt))
                continue
            return error.code, _decode(error.read())
        except (urllib.error.URLError, TimeoutError, ConnectionError):
            if attempt < retries:
                time.sleep(min(60, 5 * 2 ** attempt))
                continue
            return 0, None
    return 0, None


def _decode(raw: bytes):
    try:
        return json.loads(raw) if raw else None
    except ValueError:
        return raw.decode(errors="replace")[:500]


class Render:
    def __init__(self) -> None:
        self.key = os.environ.get("RENDER_API_KEY", "")
        self.service = os.environ.get("RENDER_SERVICE_ID", "")
        if not self.key or not self.service:
            sys.exit("RENDER_API_KEY and RENDER_SERVICE_ID are required (see docs/deployment.md)")
        mask(self.key)

    def call(self, method: str, path: str, body: dict | None = None):
        status, data = http(method, API + path, body=body, headers={"Authorization": f"Bearer {self.key}"})
        if status == 401:
            sys.exit("Render rejected RENDER_API_KEY (401). An owner must replace the secret; see docs/deployment.md")
        return status, data

    def service_info(self) -> dict:
        status, data = self.call("GET", f"/services/{self.service}")
        if status != 200:
            sys.exit(f"could not read Render service {self.service}: HTTP {status}")
        return data

    def deploys(self, limit: int = 20) -> list[dict]:
        status, data = self.call("GET", f"/services/{self.service}/deploys?limit={limit}")
        if status != 200 or not isinstance(data, list):
            sys.exit(f"could not list deploys: HTTP {status}")
        return [item.get("deploy", item) for item in data]

    def deploy(self, deploy_id: str) -> dict:
        status, data = self.call("GET", f"/services/{self.service}/deploys/{deploy_id}")
        if status != 200:
            raise RuntimeError(f"could not read deploy {deploy_id}: HTTP {status}")
        return data

    def live(self) -> dict | None:
        return next((d for d in self.deploys() if d.get("status") == "live"), None)

    def ensure_managed(self) -> None:
        """GitHub Actions drives releases, so Render's own auto-deploy must be off (otherwise every merge
        builds twice, and Render's 'wait for checks' would wait on this very job)."""
        info = self.service_info()
        trigger = info.get("autoDeployTrigger") or ("off" if info.get("autoDeploy") == "no" else "on")
        if trigger == "off":
            return
        status, _ = self.call("PATCH", f"/services/{self.service}", {"autoDeployTrigger": "off"})
        if status != 200:
            status, _ = self.call("PATCH", f"/services/{self.service}", {"autoDeploy": "no"})
        if status == 200:
            annotate("notice", f"Turned off Render's own auto-deploy (was '{trigger}'); GitHub Actions deploys now.")
        else:
            annotate("warning", f"Couldn't turn off Render auto-deploy (HTTP {status}); builds may run twice.")

    def wait(self, deploy_id: str, timeout_s: int = 25 * 60) -> dict:
        deadline = time.time() + timeout_s
        last = None
        while True:
            current = self.deploy(deploy_id)
            status = current.get("status")
            if status != last:
                log(f"  {datetime.now(UTC):%H:%M:%S} deploy {deploy_id}: {status}")
                last = status
            if status in TERMINAL_OK | TERMINAL_BAD | SUPERSEDED:
                return current
            if time.time() > deadline:
                current["status"] = "timed_out"
                return current
            time.sleep(15)

    def failure_logs(self, deploy: dict, owner_id: str | None) -> str:
        """Best-effort excerpt of build/startup errors. Filtered to error-looking lines, because workflow logs
        on a public repo are public; application request logs are never printed."""
        if not owner_id:
            return ""
        start = deploy.get("createdAt") or (datetime.now(UTC) - timedelta(minutes=30)).isoformat()
        end = deploy.get("finishedAt") or datetime.now(UTC).isoformat()
        query = urllib.parse.urlencode({"ownerId": owner_id, "resource": self.service, "startTime": start,
                                        "endTime": end, "limit": 200, "direction": "forward"})
        status, data = self.call("GET", f"/logs?{query}")
        if status != 200 or not isinstance(data, dict):
            return ""
        keep = ("error", "exception", "traceback", "failed", "applied ", "migrat", "valueerror", "permission",
                "does not exist", "violates", "killed", "exited", "out of memory")
        lines = [entry.get("message", "") for entry in data.get("logs", [])]
        interesting = [line for line in lines if any(k in line.lower() for k in keep)]
        return "\n".join(interesting[-60:])


# ---------------------------------------------------------------- smoke checks (read-only)

def smoke(base_url: str, expect_commit: str | None = None, *, password: str | None = None,
          dev_handle: str = "demo", wake_timeout_s: int = 240) -> list[str]:
    """Return a list of failures (empty = healthy)."""
    base = base_url.rstrip("/")
    failures: list[str] = []
    deadline = time.time() + wake_timeout_s
    while True:  # free instances may be asleep; give them time to wake
        status, ready = http("GET", base + "/readyz", timeout=60, retries=1)
        if status == 200 or time.time() > deadline:
            break
        time.sleep(10)
    if status != 200 or not isinstance(ready, dict):
        failures.append(f"/readyz returned {status}: {ready}")
        return failures
    log(f"  readyz: commit={ready.get('commit')} timescale={ready.get('timescale')} "
        f"migrations={ready.get('migrations', {}).get('latest')} pending={ready.get('migrations', {}).get('pending')}")
    if expect_commit and ready.get("commit") and not ready["commit"].startswith(expect_commit[:12]):
        failures.append(f"live commit is {ready['commit'][:12]}, expected {expect_commit[:12]}")
    if ready.get("migrations", {}).get("pending"):
        failures.append(f"migrations pending: {ready['migrations']['pending']}")

    status, spec = http("GET", base + "/openapi.json", timeout=60)
    if status != 200 or not isinstance(spec, dict):
        failures.append(f"/openapi.json returned {status}")
    else:
        missing = [p for p in CORE_PATHS if p not in spec.get("paths", {})]
        if missing:
            failures.append(f"routes missing from the API: {missing}")

    status, _ = http("GET", base + "/v1/me", timeout=30)
    if status != 401:
        failures.append(f"anonymous /v1/me returned {status}, expected 401")

    if password is not None or os.environ.get("AGORA_SMOKE_DEV_LOGIN"):
        body = {"handle": dev_handle, **({"password": password} if password else {})}
        status, token = http("POST", base + "/v1/dev/login", body=body, timeout=60)
        if status != 200 or not isinstance(token, dict):
            failures.append(f"demo sign-in returned {status}")
        else:
            mask(token["access_token"])
            auth = {"Authorization": f"Bearer {token['access_token']}"}
            for path, need_items in (("/v1/me", False), ("/v1/demo/profile", False), ("/v1/inventory", True),
                                     ("/v1/wishlist", False), ("/v1/lists", False),
                                     ("/v1/forecasts/runouts?within=30d", False), ("/v1/agent/intents", False)):
                status, data = http("GET", base + path, headers=auth, timeout=60)
                if status != 200:
                    failures.append(f"signed-in GET {path} returned {status}")
                elif need_items and not data:
                    failures.append(f"signed-in GET {path} returned no items for the demo account")
    return failures


# ---------------------------------------------------------------- commands

def cmd_status(args) -> int:
    render = Render()
    info = render.service_info()
    rows = ["| Deploy | Status | Commit | Trigger | Finished |", "|---|---|---|---|---|"]
    for d in render.deploys(10):
        commit = (d.get("commit") or {}).get("id", "")[:12]
        rows.append(f"| `{d['id']}` | {d.get('status')} | `{commit}` | {d.get('trigger')} | {d.get('finishedAt') or ''} |")
    trigger = info.get("autoDeployTrigger") or info.get("autoDeploy")
    summary(f"### Production status\n\nService `{render.service}` · Render auto-deploy: `{trigger}`\n\n" + "\n".join(rows))
    base = os.environ.get("AGORA_API_URL")
    if base:
        failures = smoke(base, password=os.environ.get("AGORA_DEMO_PASSWORD") or None)
        summary("Smoke: " + ("all checks passed" if not failures else "**failing**: " + "; ".join(failures)))
        return 1 if failures else 0
    return 0


def _smoke_or_report(commit: str | None) -> list[str]:
    base = os.environ.get("AGORA_API_URL", "")
    if not base:
        annotate("warning", "AGORA_API_URL is not set; skipped smoke checks")
        return []
    return smoke(base, commit, password=os.environ.get("AGORA_DEMO_PASSWORD") or None)


def cmd_deploy(args) -> int:
    render = Render()
    render.ensure_managed()
    commit = args.commit
    previous = render.live()
    previous_commit = ((previous or {}).get("commit") or {}).get("id")
    output("previous_commit", previous_commit or "")
    log(f"live before release: {previous_commit or 'none'} ({(previous or {}).get('id')})")

    if previous_commit == commit:
        log("that commit is already live; verifying only")
        failures = _smoke_or_report(commit)
    elif previous_commit and args.paths and _unchanged(previous_commit, commit, args.paths):
        # Saves Render build minutes: nothing the image is built from changed since the live release.
        log(f"no changes under {args.paths} since the live release; skipping the build")
        paths = " ".join(args.paths)
        summary(f"### No release needed\n\nNothing under `{paths}` changed between the live "
                f"release `{previous_commit[:12]}` and `{commit[:12]}`.")
        failures = _smoke_or_report(None)
    else:
        status, created = render.call("POST", f"/services/{render.service}/deploys", {"commitId": commit})
        if status not in (200, 201, 202):
            annotate("error", f"Render refused the deploy (HTTP {status}): {created}")
            return 1
        if not isinstance(created, dict) or "id" not in created:  # 202 Queued has no body: find it
            time.sleep(10)
            created = next((d for d in render.deploys(5) if (d.get("commit") or {}).get("id") == commit), None)
            if not created:
                annotate("error", "Render queued the deploy but it could not be found")
                return 1
        log(f"started deploy {created['id']} for {commit[:12]}")
        result = render.wait(created["id"])
        state = result.get("status")
        if state in SUPERSEDED:
            annotate("notice", f"Deploy {created['id']} was superseded by a newer release; nothing to verify.")
            summary(f"### Superseded\n\n`{commit[:12]}` was replaced by a newer deploy before it finished.")
            return 0
        if state != "live":
            excerpt = render.failure_logs(result, render.service_info().get("ownerId"))
            if excerpt:  # in the log too, so `gh run view --log-failed` shows the cause
                log("error lines from Render:
" + excerpt)
            still = smoke(os.environ["AGORA_API_URL"], previous_commit) if os.environ.get("AGORA_API_URL") else []
            annotate("error", f"Release {commit[:12]} failed on Render ({state}). Production stayed on "
                              f"{(previous_commit or '?')[:12]}" + (" and is healthy." if not still else
                                                                     f", which is UNHEALTHY: {still}"))
            summary(f"### Release failed: `{state}`\n\nRender kept the previous release "
                    f"`{(previous_commit or '?')[:12]}` serving traffic.\n\n"
                    + (f"Error lines from Render:\n\n```\n{excerpt}\n```\n" if excerpt else "")
                    + "Fix forward with a new commit, or see docs/deployment.md#when-a-release-fails.")
            return 1
        failures = _smoke_or_report(commit)

    if not failures:
        summary(f"### Released `{commit[:12]}`\n\nLive on Render and all smoke checks passed.")
        return 0
    annotate("error", f"Release {commit[:12]} is live but failing checks: {'; '.join(failures)}")
    if not args.auto_rollback or not previous or previous_commit == commit:
        summary("### Live but failing checks\n\n- " + "\n- ".join(failures))
        return 1
    log(f"rolling back to {previous['id']} ({previous_commit[:12]})")
    status, rolled = render.call("POST", f"/services/{render.service}/rollback", {"deployId": previous["id"]})
    rollback_ok = status in (200, 201, 202) and isinstance(rolled, dict) and \
        render.wait(rolled["id"]).get("status") == "live"
    after = _smoke_or_report(previous_commit) if rollback_ok else ["rollback did not complete"]
    summary(f"### Release `{commit[:12]}` failed checks and was rolled back\n\n- " + "\n- ".join(failures)
            + f"\n\nProduction is back on `{previous_commit[:12]}`: "
            + ("healthy." if not after else f"**still failing**: {after}")
            + "\n\nCode was rolled back; the database was not. Fix forward with a new commit.")
    annotate("error" if after else "warning",
             f"Rolled back to {previous_commit[:12]}" + (" (healthy)" if not after else f" but still failing: {after}"))
    return 1


def _unchanged(old: str, new: str, paths: list[str]) -> bool:
    import subprocess

    result = subprocess.run(["git", "diff", "--quiet", old, new, "--", *paths], capture_output=True)  # noqa: S603, S607
    return result.returncode == 0  # 1 = differences, 128 = unknown commit (then deploy to be safe)


def cmd_rollback(args) -> int:
    render = Render()
    deploys = render.deploys(30)
    live = next((d for d in deploys if d.get("status") == "live"), None)
    live_commit = ((live or {}).get("commit") or {}).get("id")
    if args.to_deploy:
        target = next((d for d in deploys if d["id"] == args.to_deploy), None)
    elif args.to_commit:
        target = next((d for d in deploys if (d.get("commit") or {}).get("id", "").startswith(args.to_commit)
                       and d.get("status") in ("live", "deactivated")), None)
    else:  # the most recent earlier release that actually went live
        target = next((d for d in deploys if d.get("status") == "deactivated"
                       and (d.get("commit") or {}).get("id") != live_commit), None)
    if not target:
        annotate("error", "No earlier successful release found to roll back to (Render keeps only recent builds). "
                          "Deploy a known-good commit instead: action=deploy, ref=<sha>.")
        return 1
    target_commit = (target.get("commit") or {}).get("id", "")
    status, rolled = render.call("POST", f"/services/{render.service}/rollback", {"deployId": target["id"]})
    if status not in (200, 201, 202) or not isinstance(rolled, dict):
        annotate("error", f"Render refused the rollback (HTTP {status}): {rolled}")
        return 1
    result = render.wait(rolled["id"])
    failures = _smoke_or_report(target_commit) if result.get("status") == "live" else [f"rollback {result.get('status')}"]
    summary(f"### Rolled back to `{target_commit[:12]}`\n\n" + ("Healthy." if not failures else "- " + "\n- ".join(failures))
            + "\n\nThe next successful merge to main deploys normally again.")
    return 1 if failures else 0


def cmd_restart(args) -> int:
    render = Render()
    status, _ = render.call("POST", f"/services/{render.service}/restart")
    if status not in (200, 202, 204):
        annotate("error", f"restart failed: HTTP {status}")
        return 1
    time.sleep(30)
    failures = _smoke_or_report(None)
    summary("### Restarted\n\n" + ("Healthy." if not failures else "- " + "\n- ".join(failures)))
    return 1 if failures else 0


def cmd_smoke(args) -> int:
    password = os.environ.get(args.password_env) if args.password_env else None
    failures = smoke(args.base_url, args.expect_commit, password=password or None, dev_handle=args.dev_handle)
    for failure in failures:
        annotate("error", failure)
    summary("### Smoke checks: " + ("passed" if not failures else "failed\n\n- " + "\n- ".join(failures)))
    return 1 if failures else 0


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("status")
    deploy = sub.add_parser("deploy")
    deploy.add_argument("--commit", required=True)
    deploy.add_argument("--auto-rollback", action="store_true")
    deploy.add_argument("--paths", nargs="*", default=[],
                        help="skip the build when none of these changed since the live release")
    rollback = sub.add_parser("rollback")
    rollback.add_argument("--to-commit")
    rollback.add_argument("--to-deploy")
    sub.add_parser("restart")
    check = sub.add_parser("smoke")
    check.add_argument("--base-url", required=True)
    check.add_argument("--expect-commit")
    check.add_argument("--password-env", help="environment variable holding the demo password")
    check.add_argument("--dev-handle", default="demo")
    args = parser.parse_args()
    handler = {"status": cmd_status, "deploy": cmd_deploy, "rollback": cmd_rollback, "restart": cmd_restart,
               "smoke": cmd_smoke}[args.command]
    sys.exit(handler(args))


if __name__ == "__main__":
    main()
