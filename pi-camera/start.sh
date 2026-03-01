#!/usr/bin/env bash
# pi-camera/start.sh — preflight check, auto-install, then launch the streamer
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

VENV="$SCRIPT_DIR/.venv"
PYTHON="$VENV/bin/python"
PIP="$VENV/bin/pip"

SEP="─────────────────────────────────────────"

ok()   { echo "  [✓] $*"; }
info() { echo "  [→] $*"; }
fail() { echo "  [✗] $*"; exit 1; }

SERVER_URL="${1:-ws://10.0.0.8:8765}"

echo ""
echo "$SEP"
echo "  CAM Stream — Camera Pi Preflight"
echo "$SEP"

# ── 1. Python ────────────────────────────────────────────────────────────────
info "Checking Python 3..."
if ! command -v python3 &>/dev/null; then
  fail "python3 not found."
fi
python3 -c "import sys; exit(0 if sys.version_info >= (3,11) else 1)" || \
  fail "Python 3.11+ required."
ok "Python $(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"

# ── 2. picamera2 (system package) ────────────────────────────────────────────
info "Checking picamera2 system package..."
if ! python3 -c "import picamera2" &>/dev/null; then
  info "picamera2 not found — installing via apt..."
  sudo apt update -q
  sudo apt install -y python3-picamera2 || fail "Could not install python3-picamera2"
fi
ok "picamera2 available"

# ── 3. Virtual environment ───────────────────────────────────────────────────
info "Checking virtual environment..."
if [ ! -d "$VENV" ]; then
  info "Creating .venv (with --system-site-packages for picamera2)..."
  python3 -m venv "$VENV" --system-site-packages
  ok "Virtual environment created"
else
  ok "Virtual environment exists"
fi

# ── 4. Dependencies ───────────────────────────────────────────────────────────
info "Checking Python dependencies..."
if ! "$PYTHON" -c "import websockets" &>/dev/null; then
  info "Installing missing packages..."
  "$PIP" install --upgrade pip -q
  "$PIP" install -r requirements.txt -q
  ok "Dependencies installed"
else
  ok "All dependencies satisfied"
fi

# ── 5. Camera module ─────────────────────────────────────────────────────────
info "Checking camera module..."
if ! "$PYTHON" -c "from picamera2 import Picamera2; c=Picamera2(); c.close()" &>/dev/null; then
  fail "Camera module not detected. Enable it with: sudo raspi-config → Interface Options → Camera"
fi
ok "Camera module detected"

# ── 6. Server reachability ───────────────────────────────────────────────────
HOST=$(echo "$SERVER_URL" | sed 's|ws://||' | cut -d: -f1)
PORT=$(echo "$SERVER_URL" | sed 's|ws://||' | cut -d: -f2)
info "Checking server reachability ($HOST:$PORT)..."
if ! nc -zw3 "$HOST" "$PORT" &>/dev/null; then
  echo "  [!] Warning: cannot reach $HOST:$PORT — server may not be running yet."
  echo "  [!] Starting anyway (will retry automatically)."
else
  ok "Server reachable at $HOST:$PORT"
fi

# ── Launch ────────────────────────────────────────────────────────────────────
echo ""
echo "$SEP"
echo "  All checks passed. Starting streamer → $SERVER_URL"
echo "$SEP"
echo ""

exec "$PYTHON" "$SCRIPT_DIR/stream.py" --server "$SERVER_URL"
