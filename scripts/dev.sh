#!/usr/bin/env bash
# Runs the Dibs server (tsx watch, :3000) and the Next dev server (:3001) together. Ctrl-C stops both.
set -um  # job control: each background job gets its own process group
cd "$(dirname "$0")/.."
export DETECTOR="${DETECTOR:-diff}" VISION="${VISION:-stub}" PRICE="${PRICE:-stub}" PAYMENTS="${PAYMENTS:-sim}" LAST_CALL_MS="${LAST_CALL_MS:-5000}"
pids=()
cleanup() { trap - INT TERM EXIT; for p in "${pids[@]}"; do kill -- -"$p" 2>/dev/null; done; wait 2>/dev/null; }
trap cleanup INT TERM EXIT
pnpm -C server exec tsx watch src/index.ts & pids+=($!)
pnpm -C web dev & pids+=($!)
echo "server http://localhost:3000   web http://localhost:3001"
wait
