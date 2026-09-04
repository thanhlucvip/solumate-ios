#!/usr/bin/env bash
set -euo pipefail

IPA_PATH="${1:-}"
BUNDLE_ID="${2:-com.idbbagent.troll}"
XCTESTCONFIG="${3:-WebDriverAgentRunner.xctest}"
UDID="${GO_IOS_UDID:-${UDID:-}}"
SKIP_INSTALL="${SKIP_INSTALL:-0}"
WDA_USE_RUNWDA="${WDA_USE_RUNWDA:-0}"
WDA_PORT="${WDA_PORT:-8000}"
MJPEG_PORT="${MJPEG_PORT:-8001}"
H264_PORT="${H264_PORT:--1}"
REALTIME_CONTROL_PORT="${REALTIME_CONTROL_PORT:-8003}"
MJPEG_SCALING_FACTOR="${MJPEG_SCALING_FACTOR:-45}"
MJPEG_SERVER_SCREENSHOT_QUALITY="${MJPEG_SERVER_SCREENSHOT_QUALITY:-20}"
MJPEG_SERVER_FRAMERATE="${MJPEG_SERVER_FRAMERATE:-30}"
MJPEG_FIX_ORIENTATION="${MJPEG_FIX_ORIENTATION:-true}"
MJPEG_FRAME_TIMEOUT="${MJPEG_FRAME_TIMEOUT:-0.45}"
WDA_STARTUP_PASSWORD="${WDA_STARTUP_PASSWORD:-}"
WDA_AUTH_TOKEN="${WDA_AUTH_TOKEN:-${WEBDRIVERAGENT_AUTH_TOKEN:-}}"
SOLUMATE_WDA_ENABLE_POINT_ARRAY="${SOLUMATE_WDA_ENABLE_POINT_ARRAY:-}"
SOLUMATE_WDA_SWIPE_SECRET="${SOLUMATE_WDA_SWIPE_SECRET:-}"
SOLUMATE_WDA_ALLOW_UNSIGNED_POINT_ARRAY="${SOLUMATE_WDA_ALLOW_UNSIGNED_POINT_ARRAY:-}"

is_truthy() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

append_prefixed_ios_envs() {
  local prefix="$1"
  local name
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    IOS_CMD+=(--env="${name}=${!name}")
  done < <(compgen -e | awk -v prefix="$prefix" 'index($0, prefix) == 1' | sort)
}

if [[ -z "$IPA_PATH" ]] && ! is_truthy "$SKIP_INSTALL"; then
  echo "Usage: $0 /path/to/WebDriverAgentRunner-Runner.ipa [bundle-id] [xctestconfig]" >&2
  echo "TrollStore/manual install mode: SKIP_INSTALL=1 $0 [optional-ipa-path] [bundle-id] [xctestconfig]" >&2
  echo "Optional env: GO_IOS_UDID, SKIP_INSTALL, WDA_USE_RUNWDA, WDA_PORT, MJPEG_PORT, H264_PORT, REALTIME_CONTROL_PORT, MJPEG_SCALING_FACTOR, MJPEG_SERVER_SCREENSHOT_QUALITY, MJPEG_SERVER_FRAMERATE, MJPEG_FIX_ORIENTATION, MJPEG_FRAME_TIMEOUT, WDA_STARTUP_PASSWORD, WDA_AUTH_TOKEN, SOLUMATE_WDA_ENABLE_POINT_ARRAY, SOLUMATE_WDA_SWIPE_SECRET, SOLUMATE_WDA_ALLOW_UNSIGNED_POINT_ARRAY" >&2
  exit 1
fi

if is_truthy "$SKIP_INSTALL"; then
  echo "Skipping IPA install. Make sure $BUNDLE_ID is already installed on the device, for example via TrollStore."
else
  echo "Installing IPA: $IPA_PATH"
  if [[ -n "$UDID" ]]; then
    ios --udid="$UDID" install --path="$IPA_PATH"
  else
    ios install --path="$IPA_PATH"
  fi
fi

if [[ -z "$WDA_STARTUP_PASSWORD" ]]; then
  echo "Warning: WDA_STARTUP_PASSWORD is empty. If your WDA build requires startup password, runwda will abort." >&2
fi
if [[ -n "$SOLUMATE_WDA_ENABLE_POINT_ARRAY" && -z "$SOLUMATE_WDA_SWIPE_SECRET" && -z "$SOLUMATE_WDA_ALLOW_UNSIGNED_POINT_ARRAY" ]]; then
  echo "Warning: SOLUMATE_WDA_ENABLE_POINT_ARRAY is set but SOLUMATE_WDA_SWIPE_SECRET is empty. Secure builds reject unsigned pointArray requests." >&2
fi

if is_truthy "$SKIP_INSTALL" && ! is_truthy "$WDA_USE_RUNWDA"; then
  echo "Launching standalone WDA with bundle id: $BUNDLE_ID (WDA:$WDA_PORT MJPEG:$MJPEG_PORT H264:$H264_PORT CTRL:$REALTIME_CONTROL_PORT scale:$MJPEG_SCALING_FACTOR quality:$MJPEG_SERVER_SCREENSHOT_QUALITY fps:$MJPEG_SERVER_FRAMERATE)"

  IOS_CMD=(ios)
  if [[ -n "$UDID" ]]; then
    IOS_CMD+=(--udid="$UDID")
  fi
  IOS_CMD+=(
    launch
    "$BUNDLE_ID"
    --kill-existing
    --env=USE_PORT="$WDA_PORT"
    --env=MJPEG_SERVER_PORT="$MJPEG_PORT"
    --env=H264_SERVER_PORT="$H264_PORT"
    --env=WDA_REALTIME_CONTROL_ENABLED=1
    --env=WDA_REALTIME_CONTROL_PORT="$REALTIME_CONTROL_PORT"
    --env=MJPEG_SCALING_FACTOR="$MJPEG_SCALING_FACTOR"
    --env=MJPEG_SERVER_SCREENSHOT_QUALITY="$MJPEG_SERVER_SCREENSHOT_QUALITY"
    --env=MJPEG_SERVER_FRAMERATE="$MJPEG_SERVER_FRAMERATE"
    --env=MJPEG_FIX_ORIENTATION="$MJPEG_FIX_ORIENTATION"
    --env=MJPEG_FRAME_TIMEOUT="$MJPEG_FRAME_TIMEOUT"
  )
  if [[ -n "$WDA_STARTUP_PASSWORD" ]]; then
    IOS_CMD+=(--env=WDA_STARTUP_PASSWORD="$WDA_STARTUP_PASSWORD")
  fi
  if [[ -n "$WDA_AUTH_TOKEN" ]]; then
    IOS_CMD+=(--env=WDA_AUTH_TOKEN="$WDA_AUTH_TOKEN")
  fi
  if [[ -n "$SOLUMATE_WDA_ENABLE_POINT_ARRAY" ]]; then
    IOS_CMD+=(--env=SOLUMATE_WDA_ENABLE_POINT_ARRAY="$SOLUMATE_WDA_ENABLE_POINT_ARRAY")
  fi
  if [[ -n "$SOLUMATE_WDA_SWIPE_SECRET" ]]; then
    IOS_CMD+=(--env=SOLUMATE_WDA_SWIPE_SECRET="$SOLUMATE_WDA_SWIPE_SECRET")
  fi
  if [[ -n "$SOLUMATE_WDA_ALLOW_UNSIGNED_POINT_ARRAY" ]]; then
    IOS_CMD+=(--env=SOLUMATE_WDA_ALLOW_UNSIGNED_POINT_ARRAY="$SOLUMATE_WDA_ALLOW_UNSIGNED_POINT_ARRAY")
  fi
  append_prefixed_ios_envs WDA_IOHID_
  append_prefixed_ios_envs WDA_REALTIME_TOUCH_

  "${IOS_CMD[@]}"
  exit 0
fi

echo "Starting WDA with bundle id: $BUNDLE_ID (WDA:$WDA_PORT MJPEG:$MJPEG_PORT H264:$H264_PORT CTRL:$REALTIME_CONTROL_PORT scale:$MJPEG_SCALING_FACTOR quality:$MJPEG_SERVER_SCREENSHOT_QUALITY fps:$MJPEG_SERVER_FRAMERATE)"

IOS_CMD=(ios)
if [[ -n "$UDID" ]]; then
  IOS_CMD+=(--udid="$UDID")
fi
IOS_CMD+=(
  runwda
  --bundleid="$BUNDLE_ID"
  --testrunnerbundleid="$BUNDLE_ID"
  --env=WDA_PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID"
  --xctestconfig="$XCTESTCONFIG"
  --env=USE_PORT="$WDA_PORT"
  --env=MJPEG_SERVER_PORT="$MJPEG_PORT"
  --env=H264_SERVER_PORT="$H264_PORT"
  --env=WDA_REALTIME_CONTROL_ENABLED=1
  --env=WDA_REALTIME_CONTROL_PORT="$REALTIME_CONTROL_PORT"
  --env=MJPEG_SCALING_FACTOR="$MJPEG_SCALING_FACTOR"
  --env=MJPEG_SERVER_SCREENSHOT_QUALITY="$MJPEG_SERVER_SCREENSHOT_QUALITY"
  --env=MJPEG_SERVER_FRAMERATE="$MJPEG_SERVER_FRAMERATE"
  --env=MJPEG_FIX_ORIENTATION="$MJPEG_FIX_ORIENTATION"
  --env=MJPEG_FRAME_TIMEOUT="$MJPEG_FRAME_TIMEOUT"
  --log-output=-
)
if [[ -n "$WDA_STARTUP_PASSWORD" ]]; then
  IOS_CMD+=(--env=WDA_STARTUP_PASSWORD="$WDA_STARTUP_PASSWORD")
fi
if [[ -n "$WDA_AUTH_TOKEN" ]]; then
  IOS_CMD+=(--env=WDA_AUTH_TOKEN="$WDA_AUTH_TOKEN")
fi
if [[ -n "$SOLUMATE_WDA_ENABLE_POINT_ARRAY" ]]; then
  IOS_CMD+=(--env=SOLUMATE_WDA_ENABLE_POINT_ARRAY="$SOLUMATE_WDA_ENABLE_POINT_ARRAY")
fi
if [[ -n "$SOLUMATE_WDA_SWIPE_SECRET" ]]; then
  IOS_CMD+=(--env=SOLUMATE_WDA_SWIPE_SECRET="$SOLUMATE_WDA_SWIPE_SECRET")
fi
if [[ -n "$SOLUMATE_WDA_ALLOW_UNSIGNED_POINT_ARRAY" ]]; then
  IOS_CMD+=(--env=SOLUMATE_WDA_ALLOW_UNSIGNED_POINT_ARRAY="$SOLUMATE_WDA_ALLOW_UNSIGNED_POINT_ARRAY")
fi
append_prefixed_ios_envs WDA_IOHID_
append_prefixed_ios_envs WDA_REALTIME_TOUCH_

"${IOS_CMD[@]}"
