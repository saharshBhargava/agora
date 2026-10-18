# Agora and Dibs

This repository holds two hackathon apps that share a team but not a runtime.

- **Agora**: the household assistant. iOS app in `Agora/`, FastAPI + Postgres backend in `backend/`,
  hosted on Render. Agents start with [CLAUDE.md](CLAUDE.md) and [docs/current-state.md](docs/current-state.md).
- **Dibs**: a shared grocery run. The shopper's iPhone livestreams the cart, housemates claim items from
  their phones or the web, and the bill splits itself. On iOS it is the Dibs tab of the Agora app
  (`Agora/Dibs/`); Node server in `server/`, web app in `web/` (web join links still work). See
  [docs/dibs/README.md](docs/dibs/README.md).

Dibs runs from a laptop for the demo and is not deployed to Render. Plans for bringing the two closer
together are in [docs/superpowers/plans/2026-10-18-dibs-merge-plan.md](docs/superpowers/plans/2026-10-18-dibs-merge-plan.md).
