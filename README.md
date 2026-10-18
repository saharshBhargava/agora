# Agora

Household shopping assistant: inventory, lists, wishlist, trips, chat, and capture — an iOS app with a FastAPI backend.

## Layout

| Path | What |
| --- | --- |
| `Agora/` | SwiftUI iOS app |
| `backend/` | FastAPI + Postgres / TimescaleDB |
| `Config/` | Shared API URL and OAuth client IDs |
| `docs/` | Deployment, API contracts, handoff |

## Live API

`https://agora-api-yq3m.onrender.com` — already set in `Config/Agora.xcconfig`.

- Docs: [/docs](https://agora-api-yq3m.onrender.com/docs)
- Ready: [/readyz](https://agora-api-yq3m.onrender.com/readyz)

Merging backend work to `main` deploys it. Details: [docs/deployment.md](docs/deployment.md).

## Sign in

**Demo:** username `demo` + the Render env value `AGORA_DEMO_PASSWORD` (shared privately).  
**Ordinary accounts:** Google Sign-In (optional Calendar).

## iOS

Open `Agora.xcodeproj` in Xcode, select the Agora scheme, run on a simulator or device.

## Backend (local)

```bash
cd backend
docker compose up -d
uv sync
uv run uvicorn app.main:create_app --factory --reload
```

Full recreate / hosted setup: [SETUP.md](SETUP.md). Backend details: [backend/README.md](backend/README.md). Frontend integration: [docs/frontend-handoff.md](docs/frontend-handoff.md).

## Agents

Before changing code, read [AGENTS.md](AGENTS.md), [docs/current-state.md](docs/current-state.md), and [docs/pr-handoff.md](docs/pr-handoff.md).
