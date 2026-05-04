#!/usr/bin/env bash

# -----------------------------------
# Robust Multi-Stream RTSP Launcher
# -----------------------------------

# Exit on errors except in background jobs
set -u

# --------------------------
# Usage
# --------------------------
if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <media-folder>"
    exit 1
fi

MEDIA_DIR="$1"
RTSP_PORT=9554
WEBRTC_COMPAT="${WEBRTC_COMPAT:-1}"
PIDS=()
STARTED_MEDIAMTX=0
MTX_PID=""
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREVIEW_CONFIG_FILE="$SCRIPT_DIR/preview-config.js"

if [[ ! -d "$MEDIA_DIR" ]]; then
    echo "❌ Error: '$MEDIA_DIR' is not a valid directory."
    exit 1
fi

# --------------------------
# Installer helpers
# --------------------------
install_ffmpeg() {
    if command -v ffmpeg >/dev/null 2>&1; then
        echo "✅ ffmpeg already installed"
        return
    fi
    echo "⚙️ Installing ffmpeg..."
    case "$(uname -s)" in
        Linux*)
            if command -v apt-get >/dev/null 2>&1; then
                sudo apt-get update && sudo apt-get install -y ffmpeg
            elif command -v yum >/dev/null 2>&1; then
                sudo yum install -y epel-release && sudo yum install -y ffmpeg ffmpeg-devel
            else
                echo "❌ Unsupported Linux package manager. Please install ffmpeg manually."
                exit 1
            fi
            ;;
        Darwin*)
            if command -v brew >/dev/null 2>&1; then
                brew install ffmpeg
            else
                echo "❌ Homebrew not found. Please install Homebrew (https://brew.sh)."
                exit 1
            fi
            ;;
        MINGW*|MSYS*|CYGWIN*)
            echo "⚠️ On Windows, please install ffmpeg manually from: https://ffmpeg.org/download.html"
            ;;
        *)
            echo "❌ Unsupported OS"
            exit 1
            ;;
    esac
}

install_mediamtx() {
    if command -v mediamtx >/dev/null 2>&1; then
        echo "✅ MediaMTX already installed"
        return
    fi
    echo "⚙️ Installing MediaMTX..."
    TMPDIR=$(mktemp -d)
    OS=$(uname -s | tr '[:upper:]' '[:lower:]')
    ARCH=$(uname -m)

    case "$ARCH" in
        x86_64) ARCH="amd64" ;;
        aarch64|arm64) ARCH="arm64" ;;
    esac

    VERSION="1.14.0" 
    URL="https://github.com/bluenviron/mediamtx/releases/download/v${VERSION}/mediamtx_v${VERSION}_${OS}_${ARCH}.tar.gz"

    echo "Downloading $URL"

    curl -L --fail "$URL" -o "$TMPDIR/mediamtx.tar.gz" || {
        echo "❌ Failed to download MediaMTX. Please check the URL or your internet connection."
        exit 1
    }

    # Verify it's a valid tar.gz file
    if ! file "$TMPDIR/mediamtx.tar.gz" | grep -q 'gzip compressed'; then
        echo "❌ Downloaded file is not a valid gzip archive."
        cat "$TMPDIR/mediamtx.tar.gz"
        exit 1
    fi

    tar -xzf "$TMPDIR/mediamtx.tar.gz" -C "$TMPDIR"

    sudo mv "$TMPDIR/mediamtx" /usr/local/bin/
    rm -rf "$TMPDIR"
    echo "✅ MediaMTX installed"
}

get_local_ip() {
    local ip=""

    if [[ "$(uname -s)" == "Darwin" ]]; then
        for iface in $(ifconfig -l | tr ' ' '\n' | grep '^en'); do
            ip=$(ifconfig "$iface" 2>/dev/null | awk '/inet / {print $2}')
            if [[ -n "$ip" ]] &&
               [[ ! "$ip" =~ ^127\. ]] &&
               [[ ! "$ip" =~ ^169\.254\. ]] &&
               [[ ! "$ip" =~ ^172\.(1[6-9]|2[0-9]|3[0-1])\. ]]; then
                echo "$ip"
                return 0
            fi
        done
    else
        # Linux
        if command -v ip >/dev/null 2>&1; then
            ip=$(ip route get 8.8.8.8 2>/dev/null | awk '/src/ {print $7}' | head -n1)
            if [[ -n "$ip" ]]; then
                echo "$ip"
                return 0
            fi
        fi
    fi

    # Fallback
    echo "127.0.0.1"
}

kill_existing_publisher() {
    local src="$1"
    local pattern="ffmpeg .*:${RTSP_PORT}/src${src}([[:space:]]|$)"
    if pgrep -f "$pattern" >/dev/null 2>&1; then
        echo "♻️ Replacing existing publisher on src${src}"
        pkill -f "$pattern" || true
        sleep 0.2
    fi
}

cleanup() {
    local exit_code=$?
    trap - EXIT INT TERM

    if [[ ${#PIDS[@]} -gt 0 ]]; then
        echo "🛑 Stopping launched stream publishers..."
        kill "${PIDS[@]}" 2>/dev/null || true
        wait "${PIDS[@]}" 2>/dev/null || true
    fi

    if [[ "$STARTED_MEDIAMTX" == "1" ]] && [[ -n "$MTX_PID" ]]; then
        echo "🛑 Stopping MediaMTX..."
        kill "$MTX_PID" 2>/dev/null || true
        wait "$MTX_PID" 2>/dev/null || true
    fi

    exit "$exit_code"
}

# --------------------------
# Main
# --------------------------
install_ffmpeg
install_mediamtx
trap cleanup EXIT INT TERM

# Start MediaMTX in background if not already running
if ! pgrep -x mediamtx >/dev/null 2>&1; then
    echo "🚀 Starting MediaMTX server..."
    mediamtx ./mediamtx.yml >/tmp/mediamtx.log 2>&1 &
    MTX_PID=$!
    STARTED_MEDIAMTX=1
    sleep 2
fi

# Confirm MediaMTX is actually listening on RTSP_PORT
if ! lsof -i :"$RTSP_PORT" >/dev/null 2>&1; then
    echo "❌ MediaMTX is not listening on port $RTSP_PORT. Check /tmp/mediamtx.log"
    exit 1
fi

LOCAL_IP=$(get_local_ip)
echo "✅ MediaMTX running on rtsp://$LOCAL_IP:$RTSP_PORT/"

# --------------------------
# Stream MP4 files in folder
# --------------------------
echo "📁 Scanning MP4 files in $MEDIA_DIR..."
mapfile -t FILES < <(find "$MEDIA_DIR" -maxdepth 1 -type f -name "*.mp4" | sort)

if [[ ${#FILES[@]} -eq 0 ]]; then
    echo "⚠️ No .mp4 files found in $MEDIA_DIR"
    exit 1
fi

cat > "$PREVIEW_CONFIG_FILE" <<EOF
window.MEDIASRC_CONFIG = {
  streamCount: ${#FILES[@]},
  baseUrl: "http://$LOCAL_IP",
  port: 8889
};
EOF
echo "🧩 Wrote preview config: $PREVIEW_CONFIG_FILE (streams=${#FILES[@]})"

for i in "${!FILES[@]}"; do
    INPUT="${FILES[$i]}"
    SRC=$i
    URL="rtsp://$LOCAL_IP:$RTSP_PORT/src$SRC"

    kill_existing_publisher "$SRC"
    echo "🎥 Streaming $INPUT -> $URL"
    if [[ "$WEBRTC_COMPAT" == "1" ]]; then
        FFMPEG_ARGS=(
            ffmpeg -nostdin -re -stream_loop -1 -i "$INPUT"
            -an
            -c:v libx264
            -preset ultrafast
            -tune zerolatency
            -pix_fmt yuv420p
            -profile:v baseline
            -x264-params "bframes=0:keyint=30:min-keyint=30:scenecut=0"
            -f rtsp "$URL"
        )
    else
        FFMPEG_ARGS=(
            ffmpeg -nostdin -re -stream_loop -1 -i "$INPUT"
            -c:v copy -an
            -f rtsp "$URL"
        )
    fi

    "${FFMPEG_ARGS[@]}" > "/tmp/ffmpeg_src${SRC}.log" 2>&1 &
    PIDS+=($!)
done

echo "✅ All available streams launched."
echo "👉 Example: ffplay rtsp://127.0.0.1:$RTSP_PORT/src1"

if [[ "$WEBRTC_COMPAT" == "1" ]]; then
    echo "✅ WebRTC compatibility mode enabled (H.264 baseline, no B-frames)."
fi

echo "🟢 Running in foreground. Press Ctrl+C to stop all launched streams."
wait
