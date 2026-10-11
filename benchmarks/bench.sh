#!/usr/bin/env bash
# FastNim HTTP benchmark using autocannon (via npx, no global install needed).
#
# Usage:
#   ./benchmarks/bench.sh
#   PORT=8090 DURATION=10 CONNECTIONS=100 PIPELINING=10 ./benchmarks/bench.sh
#
# Env knobs (with defaults):
#   PORT         server port (8090)
#   DURATION     seconds measured per endpoint (10)
#   WARMUP       warmup seconds per endpoint, excluded from results (2)
#   CONNECTIONS  concurrent connections (100)
#   PIPELINING   pipelined requests per connection (10)
#
# The script builds benchmarks/server.nim in release mode, starts it,
# waits until it answers, runs autocannon against one GET, one
# path+query GET, and one JSON POST endpoint, then stops the server.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT="${PORT:-8090}"
DURATION="${DURATION:-10}"
WARMUP="${WARMUP:-2}"
CONNECTIONS="${CONNECTIONS:-100}"
PIPELINING="${PIPELINING:-10}"
BASE="http://127.0.0.1:${PORT}"
SERVER_BIN="${ROOT}/benchmarks/server"

echo "==> Building benchmark server (release)"
nim c -d:release --path:src "${ROOT}/benchmarks/server.nim"

echo "==> Starting server on port ${PORT}"
PORT="${PORT}" "${SERVER_BIN}" &
SERVER_PID=$!
trap 'kill "${SERVER_PID}" 2>/dev/null || true' EXIT

echo "==> Waiting for server readiness"
for _ in $(seq 1 150); do
  if curl -sf "${BASE}/hello" > /dev/null 2>&1; then
    READY=1
    break
  fi
  sleep 0.2
done
if [ "${READY:-0}" -ne 1 ]; then
  echo "Server did not become ready on ${BASE}" >&2
  exit 1
fi

run_autocannon() {
  npx -y autocannon \
    -c "${CONNECTIONS}" -d "${DURATION}" -p "${PIPELINING}" \
    --warmup "${WARMUP}" \
    "$@"
}

echo
echo "==> GET /hello (tiny JSON baseline)"
run_autocannon "${BASE}/hello"

echo
echo "==> GET /items/{id} (path + query params)"
run_autocannon "${BASE}/items/42?page=3&limit=20"

echo
echo "==> POST /items (JSON body)"
run_autocannon -m POST \
  -H 'content-type: application/json' \
  -b '{"display_name":"bench"}' \
  "${BASE}/items"

echo
echo "==> Done (server stopped)"
