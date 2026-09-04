#!/usr/bin/env bash
set -euo pipefail

WDA_URL="${WDA_URL:-http://127.0.0.1:8000/status}"
MJPEG_URL="${MJPEG_URL:-http://127.0.0.1:8001/}"

echo "== WDA status =="
curl -fsS "$WDA_URL" || true
printf '\n\n'

echo "== MJPEG headers =="
curl -I "$MJPEG_URL" || true
printf '\n'

echo "== Realtime control ping =="
printf '{"type":"ping"}\n' | nc -w 2 127.0.0.1 8003 || true
printf '\n'
