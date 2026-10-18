"""Run the whole backend on this machine, configured exactly like the hosted demo:

    uv run python -m app.tools.local_demo            # from backend/
    uv run python -m app.tools.local_demo --tunnel   # also give it a public HTTPS URL (needs cloudflared)
    uv run python -m app.tools.local_demo --tunnel --import-snapshot ../demo-snapshot.zip   # hosted data, locally

Database, first match wins: --database-url / AGORA_DATABASE_URL (e.g. the Tiger URL, if only hosting is down),
then the Docker TimescaleDB from docker-compose.yml, then an embedded Postgres that needs no install at all.
It migrates, seeds the demo accounts, accepts the iOS app's Google sign-in plus /v1/dev/login, and serves on
0.0.0.0:8000. With --tunnel it updates AGORA_API_BASE_URL in Config/Local.xcconfig so a rebuilt iOS app points here.
"""

import argparse
import os
import re
import secrets
import shutil
import subprocess
import sys
import time
from pathlib import Path

BACKEND = Path(__file__).resolve().parents[2]
REPO = BACKEND.parent
DATA = BACKEND / ".data"
DOCKER_URL = "postgresql://agora:agora-dev-only@127.0.0.1:5433/agora"
XCCONFIG = REPO / "Config" / "Agora.xcconfig"
LOCAL_XCCONFIG = REPO / "Config" / "Local.xcconfig"


def say(message: str) -> None:
    print(f"[local-demo] {message}", flush=True)


def ios_client_id() -> str | None:
    for path in (LOCAL_XCCONFIG, XCCONFIG):
        if path.is_file():
            match = re.search(r"^AGORA_GOOGLE_IOS_CLIENT_ID\s*=\s*(\S+)", path.read_text(encoding="utf-8"), re.M)
            if match and "example" not in match.group(1):
                return match.group(1)
    return None


def docker_database() -> str | None:
    if not shutil.which("docker"):
        return None
    if subprocess.run(["docker", "info"], capture_output=True).returncode != 0:  # noqa: S603, S607
        return None
    say("starting TimescaleDB in Docker...")
    subprocess.run(["docker", "compose", "up", "-d", "--wait", "db"], cwd=BACKEND, check=True)  # noqa: S603, S607
    return DOCKER_URL


def embedded_database() -> str:
    """A private Postgres via the pgserver wheel (no TimescaleDB; the app falls back to plain SQL)."""
    say("no Docker: starting an embedded Postgres (first run downloads it)...")
    script = ("import pgserver,sys; s=pgserver.get_server(sys.argv[1], cleanup_mode=None); "
              "print('URI=' + s.get_uri())")
    result = subprocess.run(  # noqa: S603
        [shutil.which("uv") or "uv", "run", "--no-project", "--python", "3.12", "--with", "pgserver", "python", "-c",
         script, str(DATA / "pg")], capture_output=True, text=True, check=True)
    uri = next(line[4:] for line in result.stdout.splitlines() if line.startswith("URI="))
    return uri


def local_secret(name: str, size: int) -> str:
    """Stable across restarts so tokens and passwords keep working; never committed (.data is gitignored)."""
    path = DATA / name
    if not path.is_file():
        DATA.mkdir(parents=True, exist_ok=True)
        path.write_text(secrets.token_urlsafe(size), encoding="utf-8")
    return path.read_text(encoding="utf-8").strip()


def start_tunnel(port: int) -> tuple[subprocess.Popen, str] | None:
    binary = shutil.which("cloudflared")
    if not binary:
        say("cloudflared not found: install it (brew install cloudflared / winget install Cloudflare.cloudflared) "
            "for an HTTPS URL. Continuing without a tunnel.")
        return None
    log = DATA / "cloudflared.log"
    DATA.mkdir(parents=True, exist_ok=True)
    with log.open("w", encoding="utf-8") as sink:  # a file, not a pipe, so a full buffer can never stall it
        process = subprocess.Popen(  # noqa: S603
            [binary, "tunnel", "--no-autoupdate", "--url", f"http://127.0.0.1:{port}"],
            stdout=sink, stderr=subprocess.STDOUT)
    for _ in range(60):
        match = re.search(r"https://[a-z0-9-]+\.trycloudflare\.com", log.read_text(encoding="utf-8", errors="ignore"))
        if match:
            return process, match.group(0)
        if process.poll() is not None:
            break
        time.sleep(0.5)
    say(f"tunnel didn't report a URL (see {log}); continuing without it.")
    process.terminate()
    return None


def point_ios_app_at(url: str) -> None:
    """Set AGORA_API_BASE_URL in Config/Local.xcconfig, keeping everything else in the file."""
    line = f"AGORA_API_BASE_URL = {url.replace('://', ':/$()/')}"
    text = LOCAL_XCCONFIG.read_text(encoding="utf-8") if LOCAL_XCCONFIG.is_file() else ""
    if re.search(r"^AGORA_API_BASE_URL\s*=.*$", text, re.M):
        text = re.sub(r"^AGORA_API_BASE_URL\s*=.*$", line, text, flags=re.M)
    else:
        text = (text.rstrip() + "\n" if text else "// Local overrides (gitignored)\n") + line + "\n"
    LOCAL_XCCONFIG.parent.mkdir(parents=True, exist_ok=True)
    LOCAL_XCCONFIG.write_text(text, encoding="utf-8")
    say(f"Config/Local.xcconfig now points the iOS app at {url} (rebuild the app).")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--port", type=int, default=int(os.environ.get("PORT", 8000)))
    parser.add_argument("--database-url", default=os.environ.get("AGORA_DATABASE_URL"))
    parser.add_argument("--tunnel", action="store_true", help="expose an HTTPS URL with cloudflared")
    parser.add_argument("--no-seed", action="store_true")
    parser.add_argument("--import-snapshot", metavar="ZIP",
                        help="replace the local data with a snapshot exported from the hosted database")
    args = parser.parse_args()

    url = args.database_url or docker_database() or embedded_database()
    env = {
        **os.environ,
        "AGORA_DATABASE_URL": url,
        "AGORA_ENV": "demo",
        "AGORA_DEV_JWT_SECRET": local_secret("dev_jwt_secret", 48),
        "AGORA_DEMO_PASSWORD": os.environ.get("AGORA_DEMO_PASSWORD") or local_secret("demo_password", 12),
        "AGORA_STORAGE_BACKEND": os.environ.get("AGORA_STORAGE_BACKEND", "db"),
        "AGORA_RUN_WORKER_IN_PROCESS": "true",
    }
    client_id = ios_client_id()
    if client_id:
        env |= {"AGORA_AUTH_MODE": "google", "AGORA_GOOGLE_IOS_CLIENT_ID": client_id}
    else:
        env["AGORA_AUTH_MODE"] = "dev"
        say("no iOS Google client ID in Config/*.xcconfig: dev login only.")
    if "AGORA_VISION_PROVIDER" not in os.environ and not (BACKEND / ".env").is_file():
        env["AGORA_VISION_PROVIDER"] = "replay"  # .env (with a Gemini key) wins when present

    python = [sys.executable, "-m"]
    say(f"database: {'(from --database-url / AGORA_DATABASE_URL)' if args.database_url else url}")
    subprocess.run([*python, "app.migrate"], cwd=BACKEND, env=env, check=True)  # noqa: S603
    if args.import_snapshot:
        if args.database_url:
            parser.error("--import-snapshot replaces data; use it with the local database, not --database-url")
        subprocess.run([*python, "app.tools.snapshot", "import", str(Path(args.import_snapshot).resolve())],  # noqa: S603
                       cwd=BACKEND, env=env, check=True)
    elif not args.no_seed:
        subprocess.run([*python, "app.seed"], cwd=BACKEND, env=env, check=True)  # noqa: S603

    tunnel = start_tunnel(args.port) if args.tunnel else None
    public = tunnel[1] if tunnel else None
    if public:
        point_ios_app_at(public)
    say(f"API:  http://localhost:{args.port}   docs: http://localhost:{args.port}/docs")
    if public:
        say(f"HTTPS: {public}   (share this with phones/teammates; it changes every run)")
    say(f"demo account: POST /v1/dev/login {{\"handle\": \"demo\", \"password\": \"{env['AGORA_DEMO_PASSWORD']}\"}}")
    if env.get("AGORA_DEMO_GOOGLE_EMAILS"):
        say(f"  ...or sign in on iOS with Google as {env['AGORA_DEMO_GOOGLE_EMAILS']}")
    else:
        say("  (set AGORA_DEMO_GOOGLE_EMAILS=<demo gmail> to also reach it from the iOS app's Google sign-in)")
    try:
        subprocess.run([*python, "uvicorn", "app.main:create_app", "--factory", "--host", "0.0.0.0",  # noqa: S104, S603
                        "--port", str(args.port)], cwd=BACKEND, env=env, check=False)
    except KeyboardInterrupt:
        pass
    finally:
        if tunnel:
            tunnel[0].terminate()


if __name__ == "__main__":
    main()
