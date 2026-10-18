# Agora and Dibs

This repository holds two hackathon apps that share a team but not a runtime.

- **Agora**: the household assistant. iOS app in `Agora/`, FastAPI + Postgres backend in `backend/`,
  hosted on Render. Agents start with [CLAUDE.md](CLAUDE.md) and [docs/current-state.md](docs/current-state.md).
- **Dibs**: a shared grocery run. The shopper's iPhone livestreams the cart, housemates claim items from
  their phones or the web, and the bill splits itself. On iOS the app opens on Dibs (the merged app in `Agora/`, named Dibs); the household features (lists, pantry, wishlist, assistant) are entries on its home
  (`Agora/Dibs/`); Node server in `server/`, web app in `web/` (web join links still work). See
  [docs/dibs/README.md](docs/dibs/README.md).

Dibs runs from a laptop for the demo and is not deployed to Render. Plans for bringing the two closer
together are in [docs/superpowers/plans/2026-10-18-dibs-merge-plan.md](docs/superpowers/plans/2026-10-18-dibs-merge-plan.md).
