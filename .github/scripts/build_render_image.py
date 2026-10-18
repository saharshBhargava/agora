"""Build the API image with Render's root-relative Docker paths, or just check them."""

import argparse
import subprocess
from pathlib import Path

import yaml


def build_command(repo: Path) -> list[str]:
    blueprint = yaml.safe_load((repo / "render.yaml").read_text(encoding="utf-8"))
    service = next(service for service in blueprint["services"] if service["name"] == "agora-api")
    if service["runtime"] != "docker":
        raise ValueError("agora-api must use the Docker runtime")
    root = (repo / service.get("rootDir", ".")).resolve()
    dockerfile = (root / service.get("dockerfilePath", "Dockerfile")).resolve()
    context = (root / service.get("dockerContext", ".")).resolve()
    if not dockerfile.is_file():
        raise FileNotFoundError(f"Render Dockerfile does not exist: {dockerfile}")
    if not context.is_dir():
        raise FileNotFoundError(f"Render Docker build context does not exist: {context}")
    return ["docker", "build", "-t", "agora-api", "-f", str(dockerfile), str(context)]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Validate paths without starting Docker")
    args = parser.parse_args()
    command = build_command(Path(__file__).resolve().parents[2])
    print(f"Render Dockerfile: {command[-2]}", flush=True)
    print(f"Render build context: {command[-1]}", flush=True)
    if not args.check:
        subprocess.run(command, check=True)  # noqa: S603 - fixed command, repository-configured paths


if __name__ == "__main__":
    main()
