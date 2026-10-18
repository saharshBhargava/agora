#!/usr/bin/env bash
# Starts the production server for the live demo: Gemini vision, the browser-agent price worker for
# QFC, 5 s last call, the same item seen again counted on its row (×2, MERGE_DUPLICATES), simulated
# payments, on port 3000.
#
#   scripts/demo-server.sh https://<tunnel>      # or: PUBLIC_URL=https://<tunnel> scripts/demo-server.sh
#
# Builds web and server first when their output is missing or older than the source (FORCE_BUILD=1
# always rebuilds). Loads server/.env (GEMINI_API_KEY) without printing it. DEMO_PORT overrides 3000.
# SIM_FAIL_CAPTURE=<names> passes through (see docs/dibs/README.md) to show a partly settled run.
# Optional, in server/.env (values never printed): TEAM_API_BASE_URL (team household API origin) fills the
# wish page with the signed-in person's household (their own token); AGORA_DEMO_PASSWORD (its demo-account
# password) is only for requests with no token. Without them it suggests from past runs.
set -euo pipefail
cd "$(dirname "$0")/.."

PUBLIC_URL="${1:-${PUBLIC_URL:-}}"
PORT="${DEMO_PORT:-3000}"

# Rebuild when the output is missing or any source file is newer than it.
stale() { # output, source dirs...
  local out=$1; shift
  [ "${FORCE_BUILD:-}" = 1 ] || [ ! -e "$out" ] || [ -n "$(find "$@" -newer "$out" -type f -print -quit 2>/dev/null)" ]
}
if stale web/out/index.html web/app web/components web/lib web/public web/next.config.mjs web/package.json; then
  echo "building web..."
  pnpm -C web build >/dev/null
fi
if stale server/dist/index.js server/src server/package.json server/tsconfig.build.json; then
  echo "building server..."
  pnpm -C server build >/dev/null
fi

if [ -f server/.env ]; then
  set -a
  # shellcheck disable=SC1091
  . server/.env
  set +a
fi
if [ -z "${GEMINI_API_KEY:-}" ]; then
  echo "GEMINI_API_KEY is not set: put it in server/.env (GEMINI_API_KEY=...) or the environment." >&2
  exit 1
fi

if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "Port $PORT is already in use. Stop that server first (this script does not kill it)." >&2
  exit 1
fi

export VISION=gemini PRICE=agent STORE_NAME=QFC PAYMENTS=sim LAST_CALL_MS=5000 DUPLICATE_MS=86400000 MERGE_DUPLICATES=1 MERGE_WINDOW_MS=3000 PORT
if [ -n "$PUBLIC_URL" ]; then
  export PUBLIC_URL="${PUBLIC_URL%/}"
  echo "Dibs demo server: $PUBLIC_URL  (local http://localhost:$PORT)"
else
  unset PUBLIC_URL
  echo "Dibs demo server: http://localhost:$PORT"
  echo "warning: no PUBLIC_URL; pass the https tunnel URL so join links and the QR work on phones." >&2
fi
if [ -n "${SIM_FAIL_CAPTURE:-}" ]; then echo "simulated capture failures for: $SIM_FAIL_CAPTURE"; fi
exec node server/dist/index.js
