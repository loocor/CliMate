#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT="${PORT:-4500}"
HOSTNAME="${TSNET_HOSTNAME:-climate-mac}"
AUTHKEY="${TS_AUTHKEY:-}"

if [[ -z "$AUTHKEY" ]]; then
  echo "Missing TS_AUTHKEY. Set it in your environment before running." >&2
  echo "Example: TS_AUTHKEY=tskey-auth-... $0" >&2
  exit 2
fi

cd "$ROOT_DIR"

LOG="$(mktemp -t climate-tsnet.XXXXXX)"
cleanup() {
  if [[ -n "${PID:-}" ]]; then
    kill "$PID" >/dev/null 2>&1 || true
    wait "$PID" >/dev/null 2>&1 || true
  fi
  rm -f "$LOG"
}
trap cleanup EXIT

echo "[test] starting embedded tailnet server on port $PORT"
cd "$ROOT_DIR/server"
TS_AUTHKEY="$AUTHKEY" go run ./cmd/climate-server --port "$PORT" --ts-hostname "$HOSTNAME" \
  | tee "$LOG" &
PID=$!

echo "[test] waiting for base URL..."
BASE_URL=""
for _ in {1..60}; do
  if grep -q "iOS base URL:" "$LOG"; then
    BASE_URL="$(sed -n 's/.*iOS base URL: //p' "$LOG" | tail -n1 | tr -d '\r')"
    break
  fi
  sleep 0.5
done

if [[ -z "$BASE_URL" ]]; then
  echo "[test] failed to detect base URL in output" >&2
  exit 1
fi

echo "[test] base URL: $BASE_URL"
echo "[test] checking local healthz..."
curl -fsS "http://127.0.0.1:${PORT}/healthz" >/dev/null
echo "[test] local healthz OK"

echo "[test] note: tailnet URL is for iOS/other tailnet clients."
echo "[test] press Ctrl+C to stop, or wait to keep running..."
wait "$PID"
