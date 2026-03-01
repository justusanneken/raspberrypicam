#!/usr/bin/env bash
# camera-mac/start.sh — preflight check, auto-install, then stream from Mac webcam
#
# Usage:
#   ./start.sh                          — stream to default server (ws://10.0.0.8:8765)
#   ./start.sh ws://192.168.1.5:8765    — stream to a custom server URL
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

VENV="$SCRIPT_DIR/.venv"
SERVER_URL="${1:-ws://10.0.0.8:8765}"
SEP="─────────────────────────────────────────"

ok()   { echo "  [✓] $*"; }
info() { echo "  [→] $*"; }
fail() { echo "  [✗] $*"; echo ""; read -rp "  Press Enter to close..."; exit 1; }

_pause_on_exit() { echo ""; read -rp "  Press Enter to close..." || true; }
trap _pause_on_exit EXIT

echo ""
echo "$SEP"
echo "  CAM Stream — Mac Camera Preflight"
echo "$SEP"

# ── 1. Python ────────────────────────────────────────────────────────────────
info "Checking Python 3..."
if command -v python3 &>/dev/null; then
  PY_CMD="python3"
elif command -v python &>/dev/null; then
  PY_CMD="python"
else
  fail "Python not found. Install from https://python.org"
fi
$PY_CMD -c "import sys; exit(0 if sys.version_info >= (3,11) else 1)" || \
  fail "Python 3.11+ required."
PY_VER=$($PY_CMD -c "import sys; print(str(sys.version_info.major) + '.' + str(sys.version_info.minor))")
ok "Python $PY_VER"

# ── 2. Virtual environment ───────────────────────────────────────────────────
info "Checking virtual environment..."
if [ ! -d "$VENV" ]; then
  info "Creating .venv..."
  $PY_CMD -m venv "$VENV"
  ok "Virtual environment created"
else
  ok "Virtual environment exists"
fi

if [ -d "$VENV/Scripts" ]; then
  PYTHON="$VENV/Scripts/python"
else
  PYTHON="$VENV/bin/python"
fi

# ── 3. Dependencies ───────────────────────────────────────────────────────────
info "Checking Python dependencies..."
if ! "$PYTHON" -c "import cv2, websockets" &>/dev/null; then
  info "Installing dependencies..."
  "$PYTHON" -m pip install --upgrade pip -q 2>/dev/null || true
  "$PYTHON" -m pip install -r requirements.txt -q
  ok "Dependencies installed"
else
  ok "All dependencies satisfied"
fi

# ── 4. Camera access ─────────────────────────────────────────────────────────
info "Checking camera access..."
"$PYTHON" -c "
import cv2, sys
cap = cv2.VideoCapture(0)
if not cap.isOpened():
    print('  [!] Camera device 0 not accessible.')
    print('  [!] On macOS: System Settings → Privacy & Security → Camera → allow Terminal')
    sys.exit(1)
cap.release()
" || fail "Camera not accessible — check macOS privacy permissions."
ok "Camera accessible"

# ── 5. Server reachability ───────────────────────────────────────────────────
HOST=$(echo "$SERVER_URL" | sed 's|ws://||' | cut -d: -f1)
PORT=$(echo "$SERVER_URL" | sed 's|ws://||' | cut -d: -f2)
info "Checking server ($HOST:$PORT)..."
if nc -zw2 "$HOST" "$PORT" &>/dev/null; then
  ok "Server reachable at $HOST:$PORT"
else
  echo "  [!] Cannot reach $HOST:$PORT — server may not be running yet."
  echo "  [!] Starting anyway (will retry automatically)."
fi

# ── Launch ────────────────────────────────────────────────────────────────────
echo ""
echo "$SEP"
echo "  All checks passed. Streaming to $SERVER_URL"
echo "  Press Ctrl+C to stop."
echo "$SEP"
echo ""

_CHILD_PID=""
cleanup() {
  echo ""
  echo "$SEP"
  echo "  Stopped."
  echo "$SEP"
  trap - EXIT
  [ -n "$_CHILD_PID" ] && kill "$_CHILD_PID" 2>/dev/null || true
  exit 0
}
trap cleanup INT TERM

RESTART_DELAY=5
while true; do
  echo "  [$(date '+%H:%M:%S')] Starting stream..."
  "$PYTHON" "$SCRIPT_DIR/stream.py" --server "$SERVER_URL" &
  _CHILD_PID=$!
  wait "$_CHILD_PID" || true
  echo ""
  echo "  [$(date '+%H:%M:%S')] Stream stopped. Restarting in ${RESTART_DELAY}s... (Ctrl+C to quit)"
  sleep $RESTART_DELAY
done
