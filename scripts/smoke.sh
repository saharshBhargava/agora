#!/usr/bin/env bash
# Builds web and server, starts the production server on a free port, and checks landing, join and POST /api/runs.
set -euo pipefail
cd "$(dirname "$0")/.."
if [ -z "${SMOKE_URL:-}" ]; then
  pnpm -C web build
  pnpm -C server build
  PORT=$(node -e 'const s=require("net").createServer().listen(0,()=>{console.log(s.address().port);s.close()})')
  PORT=$PORT DETECTOR=diff VISION=stub PRICE=stub PAYMENTS=sim LAST_CALL_MS=5000 node server/dist/index.js &
  SERVER_PID=$!
  trap 'kill $SERVER_PID 2>/dev/null || true' EXIT
  BASE="http://localhost:$PORT"
else
  BASE="$SMOKE_URL"  # e.g. a running container
fi
fail() { echo "SMOKE FAIL: $1"; exit 1; }
ready=0
for _ in $(seq 1 50); do
  if [ -n "${SERVER_PID:-}" ] && ! kill -0 "$SERVER_PID" 2>/dev/null; then fail "server exited"; fi
  if curl -fs "$BASE/api/health" >/dev/null 2>&1; then ready=1; break; fi
  sleep 0.2
done
[ "$ready" = 1 ] || fail "server not ready"
check() { # name, expected substring, curl args...
  local name=$1 want=$2 body; shift 2
  body=$(curl -fs "$@") || fail "$name (request)"
  grep -qi -- "$want" <<<"$body" || fail "$name (body)"
}
check health '"ok":true' "$BASE/api/health"
check "landing /" '<html' "$BASE/"
check "/join" '<html' "$BASE/join?run=x"
for p in claim shopper settle; do check "/$p" '<html' "$BASE/$p"; done
check "POST /api/runs" '"runId"' -X POST "$BASE/api/runs"
echo "SMOKE OK $BASE"
