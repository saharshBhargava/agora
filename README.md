# Agora

Hackathon monorepo with two related products that share this tree side by side:

| Product | Paths | Role |
|---|---|---|
| **Agora** | `Agora/`, `backend/`, `Config/` | Household inventory, shopping lists, wishlist, Calendar trips, agent commerce. Hosted API on Render. |
| **Dibs** | `ios/`, `server/`, `web/`, `scripts/{dev,demo-server,smoke}.sh` | Live cart camera → claim chips → split settle. Demo on a laptop + tunnel; **not** on Render. |

## Agora (household app)

- Setup and local fallback: [SETUP.md](SETUP.md)
- Current facts: [docs/current-state.md](docs/current-state.md)
- Deploy / ops: [docs/deployment.md](docs/deployment.md)
- Frontend sign-in: [docs/frontend-handoff.md](docs/frontend-handoff.md)
- Agent rules: [CLAUDE.md](CLAUDE.md), [AGENTS.md](AGENTS.md)

Merging backend changes to `main` deploys `agora-api` automatically. Dibs paths do not.

## Dibs (shop-together demo)

Full runbook, env flags, and security notes: **[docs/dibs/README.md](docs/dibs/README.md)**.

```sh
pnpm install
scripts/dev.sh            # stub server :3000 + Next :3001
scripts/demo-server.sh https://<tunnel>   # live Gemini + QFC worker demo
pnpm -r test && scripts/smoke.sh
```

Side-by-side merge plan (Phase A done on this branch; later phases are backlog):
[docs/dibs/merge-plan.md](docs/dibs/merge-plan.md).
