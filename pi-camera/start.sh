#!/usr/bin/env bash
# pi-camera/start.sh
# Preflight check, auto-install, then launch the Pi 5 camera streamer.
#
# Usage:
#   ./start.sh                       — stream to ws://10.0.0.8:8765
#   ./start.sh ws://192.168.1.5:8765 — custom server URL
#   ./start.sh stop                  — stop a running instance
#   ./start.sh status                — show if running
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

VENV="$SCRIPT_DIR/.venv"
PYTHON="$VENV/bin/python"
PIDFILE="$SCRIPT_DIR/.cam.pid"
SEP="─────────────────────────────────────────"
SERVER_URL="${1:-ws://10.0.0.8:8765}"

ok()   { echo "  [✓] $*"; }
info() { echo "  [→] $*"; }
warn() { echo "  [!] $*"; }
fail() { echo "  [✗] $*"; echo ""; read -rp "  Press Enter to close..."; exit 1; }

_pause_on_exit() { echo ""; read -rp "  Press Enter to close..." || true; }
trap _pause_on_exit EXIT

# ── stop / status ─────────────────────────────────────────────────────────────
if [ "${1:-}" = "stop" ]; then
  if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    kill "$(cat "$PIDFILE")" && rm -f "$PIDFILE"
    ok "Streamer stopped."
  else
    warn "No running streamer found."
    rm -f "$PIDFILE"
  fi
  echo ""; trap - EXIT; exit 0
fi

if [ "${1:-}" = "status" ]; then
  echo ""
  if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    ok "Streamer is RUNNING (PID $(cat "$PIDFILE")) → $SERVER_URL"
  else
    warn "Streamer is STOPPED"
    rm -f "$PIDFILE" 2>/dev/null || true
  fi
  echo ""; trap - EXIT; exit 0
fi

echo ""
echo "$SEP"
echo "  CAM — Pi 5 + Camera v2 Preflight"
echo "$SEP"

# ── 0. Platform ───────────────────────────────────────────────────────────────
info "Checking platform..."
if ! grep -qi "raspberry" /proc/device-tree/model 2>/dev/null && \
   ! grep -qi "raspberry" /proc/cpuinfo 2>/dev/null; then
  fail "Raspberry Pi not detected. On macOS use: cd ../camera-mac && ./start.sh"
fi
ok "Raspberry Pi detected"

# ── 1. Python ────────────────────────────────────────────────────────────────
info "Checking Python 3.11+..."
python3 -c "import sys; exit(0 if sys.version_info >= (3,11) else 1)" || \
  fail "Python 3.11+ required. Run: sudo apt install python3"
PY_VER=$(python3 -c "import sys; print(str(sys.version_info.major)+'.'+str(sys.version_info.minor))")
ok "Python $PY_VER"

# ── 2. picamera2 (must be system apt package on Bookworm) ────────────────────
info "Checking picamera2..."
if ! python3 -c "import picamera2" &>/dev/null; then
  info "Installing picamera2 via apt..."
  sudo apt update -q && sudo apt install -y python3-picamera2 python3-opencv || \
    fail "apt install failed. Check your internet connection."
fi
ok "picamera2 available"

# ── 3. libcamera ─────────────────────────────────────────────────────────────
info "Checking libcamera..."
if ! command -v libcamera-hello &>/dev/null; then
  info "Installing libcamera-apps..."
  sudo apt install -y libcamera-apps libcamera-tools -q
fi
ok "libcamera available"

# ── 4. Virtual environment ───────────────────────────────────────────────────
info "Checking virtual environment..."
if [ ! -d "$VENV" ]; then
  info "Creating .venv with --system-site-packages (needed for picamera2 + cv2)..."
  python3 -m venv "$VENV" --system-site-packages
  ok "Created"
else
  ok "Exists"
fi

# ── 5. Python dependencies ───────────────────────────────────────────────────
info "Checking Python dependencies..."
if ! "$PYTHON" -c "import websockets, cv2" &>/dev/null; then
  info "Installing dependencies..."
  "$PYTHON" -m pip install --upgrade pip -q 2>/dev/null || true
  "$PYTHON" -m pip install -r requirements.txt -q
  ok "Installed"
else
  ok "All satisfied"
fi

# ── 6. Camera hardware ───────────────────────────────────────────────────────
info "Checking camera hardware..."
if ! "$PYTHON" -c "
from picamera2 import Picamera2
cams = Picamera2.global_camera_info()
if not cams:
    raise RuntimeError('no cameras')
" &>/dev/null; then
  fail "No camera detected. Check cable and run: sudo raspi-config → Interface Options → Camera"
fi
ok "Camera hardware detected"

# ── 7. Server reachability ───────────────────────────────────────────────────
HOST=$(echo "$SERVER_URL" | sed 's|ws://||' | cut -d: -f1)
PORT=$(echo "$SERVER_URL" | sed 's|ws://||' | cut -d: -f2)
info "Checking server ($HOST:$PORT)..."
if nc -zw3 "$HOST" "$PORT" &>/dev/null; then
  ok "Server reachable"
else
  warn "Cannot reach $HOST:$PORT — starting anyway, will retry automatically"
fi

# ── Launch ────────────────────────────────────────────────────────────────────
echo ""
echo "$SEP"
echo "  All checks passed."
echo "  Streaming to: $SERVER_URL"
echo "  Ctrl+C or './start.sh stop' to stop."
echo "$SEP"
echo ""

echo $$ > "$PIDFILE"

_CHILD_PID=""
cleanup() {
  [ -n "$_CHILD_PID" ] && kill "$_CHILD_PID" 2>/dev/null || true
  rm -f "$PIDFILE"
  echo ""; echo "  Stopped."; echo ""
  trap - EXIT; exit 0
}
trap cleanup INT TERM

BACKOFF=3
while true; do
  echo "  [$(date '+%H:%M:%S')] Starting stream.py..."
  "$PYTHON" "$SCRIPT_DIR/stream.py" --server "$SERVER_URL" &
  _CHILD_PID=$!
  wait "$_CHILD_PID" || true
  echo "  [$(date '+%H:%M:%S')] Exited. Restarting in ${BACKOFF}s... (Ctrl+C to stop)"
  sleep $BACKOFF
  [ $BACKOFF -lt 30 ] && BACKOFF=$((BACKOFF * 2))
done
