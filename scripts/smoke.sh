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
for _ in $(seq 1 50); do curl -fs "$BASE/api/health" >/dev/null 2>&1 && break; sleep 0.2; done
fail() { echo "SMOKE FAIL: $1"; exit 1; }
curl -fs "$BASE/api/health" | grep -q '"ok":true' || fail "health"
curl -fs "$BASE/" | grep -qi '<html' || fail "landing /"
curl -fs "$BASE/join?run=x" | grep -qi '<html' || fail "/join"
for p in claim shopper settle; do curl -fs "$BASE/$p" | grep -qi '<html' || fail "/$p"; done
curl -fs -X POST "$BASE/api/runs" | grep -q '"runId"' || fail "POST /api/runs"
echo "SMOKE OK $BASE"
