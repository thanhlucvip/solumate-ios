#!/usr/bin/env bash
set -euo pipefail

HOST_WDA_PORT="${HOST_WDA_PORT:-8000}"
HOST_MJPEG_PORT="${HOST_MJPEG_PORT:-8001}"
HOST_REALTIME_CONTROL_PORT="${HOST_REALTIME_CONTROL_PORT:-8003}"
DEVICE_WDA_PORT="${DEVICE_WDA_PORT:-8000}"
DEVICE_MJPEG_PORT="${DEVICE_MJPEG_PORT:-8001}"
DEVICE_REALTIME_CONTROL_PORT="${DEVICE_REALTIME_CONTROL_PORT:-8003}"

cleanup() {
  if [[ -n "${PID1:-}" ]]; then kill "$PID1" 2>/dev/null || true; fi
  if [[ -n "${PID2:-}" ]]; then kill "$PID2" 2>/dev/null || true; fi
  if [[ -n "${PID3:-}" ]]; then kill "$PID3" 2>/dev/null || true; fi
}
trap cleanup EXIT INT TERM

echo "Forwarding WDA:   localhost:${HOST_WDA_PORT} -> device:${DEVICE_WDA_PORT}"
ios forward "$HOST_WDA_PORT" "$DEVICE_WDA_PORT" &
PID1=$!

echo "Forwarding MJPEG: localhost:${HOST_MJPEG_PORT} -> device:${DEVICE_MJPEG_PORT}"
ios forward "$HOST_MJPEG_PORT" "$DEVICE_MJPEG_PORT" &
PID2=$!

echo "Forwarding CTRL:  localhost:${HOST_REALTIME_CONTROL_PORT} -> device:${DEVICE_REALTIME_CONTROL_PORT}"
ios forward "$HOST_REALTIME_CONTROL_PORT" "$DEVICE_REALTIME_CONTROL_PORT" &
PID3=$!

wait
