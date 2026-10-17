FROM python:3.12-slim AS base

ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 UV_COMPILE_BYTECODE=1 UV_LINK_MODE=copy
RUN apt-get update && apt-get install -y --no-install-recommends ffmpeg && rm -rf /var/lib/apt/lists/*
COPY --from=ghcr.io/astral-sh/uv:0.11.2 /uv /usr/local/bin/uv

WORKDIR /app
COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --no-dev --no-install-project
COPY app ./app
COPY migrations ./migrations
COPY seed ./seed

RUN useradd --create-home --uid 10001 agora && mkdir -p /app/.data && chown agora /app/.data
USER agora
ENV PATH="/app/.venv/bin:$PATH"
EXPOSE 8080

# Migrations run on boot under an advisory lock, so multiple machines can start at once safely.
CMD ["sh", "-c", "python -m app.migrate && exec uvicorn app.main:create_app --factory --host 0.0.0.0 --port 8080 --proxy-headers --forwarded-allow-ips='*'"]
