#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${MEDIASRC_UDP_STATE_DIR:-$SCRIPT_DIR/.mediasrc-udp}"
PREVIEW_CONFIG_FILE="${MEDIASRC_UDP_PREVIEW_CONFIG_FILE:-$SCRIPT_DIR/preview-udp-config.js}"
RTSP_PORT="${RTSP_PORT:-8554}"
PREVIEW_HTTP_PORT="${PREVIEW_HTTP_PORT:-8889}"
HOST_OVERRIDE="${MEDIASRC_UDP_HOST:-}"
STREAMS=1
PORT_BASE=5600
PATH_PREFIX="udp"
DRY_RUN=0
PIDS=()
STARTED_MEDIAMTX=0
MTX_PID=""
LOG_DIR=""

usage() {
    cat <<'EOF'
Usage: ./mediasrc-udp.sh [--streams N] [--port-base PORT] [--path-prefix PREFIX] [--dry-run]

Relays incoming H.264 RTP/UDP streams into MediaMTX RTSP paths for browser preview.
EOF
}

install_ffmpeg() {
    if command -v ffmpeg >/dev/null 2>&1; then
        return
    fi
    echo "❌ ffmpeg is required but not installed."
    exit 1
}

install_mediamtx() {
    if command -v mediamtx >/dev/null 2>&1; then
        return
    fi
    echo "❌ mediamtx is required but not installed."
    exit 1
}

port_is_listening() {
    local port="$1"

    if command -v ss >/dev/null 2>&1; then
        ss -ltn "sport = :${port}" 2>/dev/null | awk 'NR > 1 {found = 1} END {exit found ? 0 : 1}'
        return
    fi

    if command -v netstat >/dev/null 2>&1; then
        netstat -ltn 2>/dev/null | awk -v port=":${port}" '$4 ~ port"$" {found = 1} END {exit found ? 0 : 1}'
        return
    fi

    python3 - "$port" <<'PY'
import socket
import sys

port = int(sys.argv[1])
sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
sock.settimeout(0.2)
try:
    sys.exit(0 if sock.connect_ex(("127.0.0.1", port)) == 0 else 1)
finally:
    sock.close()
PY
}

wait_for_port() {
    local port="$1"
    local retries="${2:-40}"

    for ((attempt = 0; attempt < retries; attempt++)); do
        if port_is_listening "$port"; then
            return 0
        fi
        sleep 0.25
    done

    return 1
}

get_local_ip() {
    local ip=""

    if [[ "$(uname -s)" == "Darwin" ]]; then
        for iface in $(ifconfig -l | tr ' ' '\n' | grep '^en'); do
            ip=$(ifconfig "$iface" 2>/dev/null | awk '/inet / {print $2}')
            if [[ -n "$ip" ]] && [[ ! "$ip" =~ ^127\. ]] && [[ ! "$ip" =~ ^169\.254\. ]]; then
                echo "$ip"
                return 0
            fi
        done
    else
        if command -v ip >/dev/null 2>&1; then
            ip=$(ip route get 8.8.8.8 2>/dev/null | awk '/src/ {print $7}' | head -n1)
            if [[ -n "$ip" ]]; then
                echo "$ip"
                return 0
            fi
        fi
    fi

    echo "127.0.0.1"
}

cleanup() {
    local exit_code=$?
    trap - EXIT INT TERM

    if [[ ${#PIDS[@]} -gt 0 ]]; then
        kill "${PIDS[@]}" 2>/dev/null || true
        wait "${PIDS[@]}" 2>/dev/null || true
    fi

    if [[ "$STARTED_MEDIAMTX" == "1" ]] && [[ -n "$MTX_PID" ]]; then
        kill "$MTX_PID" 2>/dev/null || true
        wait "$MTX_PID" 2>/dev/null || true
    fi

    exit "$exit_code"
}

write_preview_config() {
    local local_ip="$1"
    mkdir -p "$(dirname "$PREVIEW_CONFIG_FILE")"
    cat > "$PREVIEW_CONFIG_FILE" <<EOF
window.MEDIASRC_UDP_CONFIG = {
  streamCount: ${STREAMS},
  baseUrl: "http://${local_ip}",
  port: ${PREVIEW_HTTP_PORT},
  pathPrefix: "${PATH_PREFIX}"
};
EOF
}

write_sdp() {
    local idx="$1"
    local udp_port=$((PORT_BASE + idx))
    mkdir -p "$STATE_DIR"
    cat > "$STATE_DIR/${PATH_PREFIX}${idx}.sdp" <<EOF
v=0
o=- 0 0 IN IP4 127.0.0.1
s=MediaSrc UDP Preview ${idx}
c=IN IP4 0.0.0.0
t=0 0
m=video ${udp_port} RTP/AVP 96
a=rtpmap:96 H264/90000
a=fmtp:96 packetization-mode=1
EOF
}

start_mediamtx() {
    install_mediamtx
    mkdir -p "$LOG_DIR"

    if ! port_is_listening "$RTSP_PORT"; then
        MTX_RTSPADDRESS=":${RTSP_PORT}" \
        MTX_WEBRTCADDRESS=":${PREVIEW_HTTP_PORT}" \
        MTX_WEBRTCADDITIONALHOSTS="${LOCAL_IP}" \
        mediamtx "$SCRIPT_DIR/mediamtx.yml" >"$LOG_DIR/mediamtx.log" 2>&1 &
        MTX_PID=$!
        STARTED_MEDIAMTX=1
    fi

    if ! wait_for_port "$RTSP_PORT"; then
        echo "❌ MediaMTX is not listening on port $RTSP_PORT. Check $LOG_DIR/mediamtx.log"
        exit 1
    fi
}

start_relays() {
    local local_ip="$1"
    install_ffmpeg

    for ((i = 0; i < STREAMS; i++)); do
        local sdp_path="$STATE_DIR/${PATH_PREFIX}${i}.sdp"
        local rtsp_url="rtsp://${local_ip}:${RTSP_PORT}/${PATH_PREFIX}${i}"
        echo "🎯 Listening on UDP port $((PORT_BASE + i)) -> ${rtsp_url}"

        ffmpeg -nostdin \
            -protocol_whitelist file,udp,rtp \
            -fflags +genpts \
            -i "$sdp_path" \
            -an \
            -c:v copy \
            -f rtsp \
            "$rtsp_url" >"$LOG_DIR/ffmpeg_${PATH_PREFIX}${i}.log" 2>&1 &
        PIDS+=($!)
    done
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --streams)
            STREAMS="$2"
            shift 2
            ;;
        --port-base)
            PORT_BASE="$2"
            shift 2
            ;;
        --path-prefix)
            PATH_PREFIX="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "❌ Unknown argument: $1"
            usage
            exit 1
            ;;
    esac
done

if [[ "$STREAMS" -le 0 ]]; then
    echo "❌ --streams must be > 0"
    exit 1
fi

trap cleanup EXIT INT TERM

LOG_DIR="$STATE_DIR/logs"
LOCAL_IP="${HOST_OVERRIDE:-$(get_local_ip)}"
write_preview_config "$LOCAL_IP"

for ((i = 0; i < STREAMS; i++)); do
    write_sdp "$i"
    echo "🧩 Prepared ${STATE_DIR}/${PATH_PREFIX}${i}.sdp"
done

for ((i = 0; i < STREAMS; i++)); do
    echo "📡 UDP port $((PORT_BASE + i)) -> rtsp://${LOCAL_IP}:${RTSP_PORT}/${PATH_PREFIX}${i}"
done

if [[ "$DRY_RUN" == "1" ]]; then
    echo "✅ Dry run complete."
    exit 0
fi

start_mediamtx
start_relays "$LOCAL_IP"

echo "✅ UDP preview relays launched."
echo "👉 Open preview-udp.html to view /${PATH_PREFIX}0, /${PATH_PREFIX}1, ..."
wait
