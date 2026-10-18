# Agent instructions

## Mandatory entry point, including after a rate-limit pause

Before editing, deploying, or resuming an old task, read these files in order:

1. [CLAUDE.md](CLAUDE.md) — repository rules, demo isolation, migrations and validation.
2. [docs/current-state.md](docs/current-state.md) — verified implementation/deployment snapshot, outstanding work,
   and the checklist for reconciling an older checkout.
3. [docs/pr-handoff.md](docs/pr-handoff.md) — merged work, superseded assumptions and migration renumbering.

Fetch `origin` and compare your branch with `origin/main` before continuing. Preserve uncommitted work;
integrate current main rather than overwriting it, resetting somebody else's worktree, or replaying a merged PR.
Do not assume your earlier chat, branch-local docs, or an old deployment URL still describe the current system.

**Merging backend work to `main` deploys it automatically.** Check the `deploy` workflow run afterwards and
fix it if it's red. Anyone can operate production from GitHub (`gh workflow run deploy.yml -f action=status`);
migrations must stay backward compatible. Details: [docs/deployment.md](docs/deployment.md).

For operations read [docs/deployment.md](docs/deployment.md); for client integration read
[docs/frontend-handoff.md](docs/frontend-handoff.md). The backend spec and original planning notes include
unimplemented proposals: they are context, not proof that a feature exists or authorization to deploy it.

Dibs, the shared grocery-run app in `ios/`, `server/` and `web/`, is separate from Agora's backend and deploy;
read [docs/dibs/README.md](docs/dibs/README.md) and the Dibs section of [CLAUDE.md](CLAUDE.md) before touching it.

