#!/bin/bash

UDID="00008120-001278CA3693C01E"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$SCRIPT_DIR/ios_stream_v1"
SERVER_PORT="${SERVER_PORT:-4200}"

ports=(8000 8001 8003 8004 46968)

pids=()

cleanup() {
    echo ""
    echo "Đang dừng tất cả forward và server..."

    for pid in "${pids[@]}"; do
        kill "$pid" 2>/dev/null
    done

    wait 2>/dev/null

    echo "Đã dừng."
    exit 0
}

load_server_port() {
    if [[ ! -f "$APP_DIR/.env" ]]; then
        return
    fi

    local env_port
    env_port="$(awk -F= '/^PORT=/{print $2; exit}' "$APP_DIR/.env" | tr -d '"'\''[:space:]')"
    if [[ "$env_port" =~ ^[0-9]+$ ]]; then
        SERVER_PORT="$env_port"
    fi
}

kill_existing_server() {
    echo ""
    echo "Đang kill server cũ trên port $SERVER_PORT..."

    local existing_pids=()
    if command -v lsof >/dev/null 2>&1; then
        while IFS= read -r pid; do
            [[ -n "$pid" ]] && existing_pids+=("$pid")
        done < <(lsof -tiTCP:"$SERVER_PORT" -sTCP:LISTEN 2>/dev/null || true)
    fi

    if [[ "${#existing_pids[@]}" -eq 0 ]]; then
        echo "Không có server cũ đang listen port $SERVER_PORT."
        return
    fi

    kill "${existing_pids[@]}" 2>/dev/null || true
    sleep 1
    kill -9 "${existing_pids[@]}" 2>/dev/null || true
    echo "Đã kill server cũ: ${existing_pids[*]}"
}

start_web_server() {
    if [[ ! -d "$APP_DIR" ]]; then
        echo "Không tìm thấy thư mục: $APP_DIR" >&2
        cleanup
    fi

    load_server_port
    cd "$APP_DIR" || cleanup
    kill_existing_server

    echo ""
    echo "Starting ios_stream_v1 server on port $SERVER_PORT..."
    node server.js &
    pids+=($!)
}

trap cleanup SIGINT SIGTERM

for port in "${ports[@]}"; do
    echo "Starting forward $port -> $port"

    ios --udid="$UDID" forward "$port" "$port" &
    pids+=($!)
done

start_web_server

echo ""
echo "======================================"
echo " iOS Port Forward đang chạy"
echo " UDID: $UDID"
echo " Ports: ${ports[*]}"
echo " Web UI: http://127.0.0.1:$SERVER_PORT"
echo "======================================"
echo "Nhấn Ctrl+C để dừng tất cả."
echo ""

wait

# Cấp quyền
# chmod +x forward.sh
# Chạy
# ./forward.sh
