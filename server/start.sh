#!/usr/bin/env bash
# server/start.sh — preflight check, auto-install, then launch the server
#
# Usage:
#   ./start.sh          — start the server (auto-restarts on crash)
#   ./start.sh stop     — stop a running background instance
#   ./start.sh status   — show whether the server is running
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

VENV="$SCRIPT_DIR/.venv"
PYTHON="$VENV/bin/python"
PIP="$VENV/bin/pip"
PIDFILE="$SCRIPT_DIR/.server.pid"

SEP="─────────────────────────────────────────"

ok()   { echo "  [✓] $*"; }
info() { echo "  [→] $*"; }
fail() { echo "  [✗] $*"; exit 1; }

# ── stop / status sub-commands ────────────────────────────────────────────────
if [ "${1:-}" = "stop" ]; then
  if [ -f "$PIDFILE" ]; then
    PID=$(cat "$PIDFILE")
    if kill -0 "$PID" 2>/dev/null; then
      echo ""
      info "Stopping server (PID $PID)..."
      kill "$PID"
      sleep 1
      kill -0 "$PID" 2>/dev/null && kill -9 "$PID" || true
      rm -f "$PIDFILE"
      ok "Server stopped."
    else
      echo "  [!] PID $PID is not running. Cleaning up stale pidfile."
      rm -f "$PIDFILE"
    fi
  else
    echo "  [!] No running server found (no .server.pid file)."
  fi
  echo ""
  exit 0
fi

if [ "${1:-}" = "status" ]; then
  echo ""
  if [ -f "$PIDFILE" ]; then
    PID=$(cat "$PIDFILE")
    if kill -0 "$PID" 2>/dev/null; then
      ok "Server is RUNNING (PID $PID)"
      echo "  Dashboard → http://$(hostname -I 2>/dev/null | awk '{print $1}' || echo localhost):5000"
    else
      echo "  [!] Server is STOPPED (stale PID $PID)"
      rm -f "$PIDFILE"
    fi
  else
    echo "  [!] Server is STOPPED"
  fi
  echo ""
  exit 0
fi

echo ""
echo "$SEP"
echo "  CAM Stream Server — Preflight"
echo "$SEP"

# ── 1. Python ────────────────────────────────────────────────────────────────
info "Checking Python 3..."
if ! command -v python3 &>/dev/null; then
  fail "python3 not found. Install Python 3.11+ and re-run."
fi
PY_VER=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
REQUIRED="3.11"
if python3 -c "import sys; exit(0 if sys.version_info >= (3,11) else 1)"; then
  ok "Python $PY_VER"
else
  fail "Python $PY_VER found but 3.11+ required."
fi

# ── 2. Virtual environment ───────────────────────────────────────────────────
info "Checking virtual environment..."
if [ ! -d "$VENV" ]; then
  info "Creating .venv..."
  python3 -m venv "$VENV"
  ok "Virtual environment created"
else
  ok "Virtual environment exists"
fi

# ── 3. Dependencies ───────────────────────────────────────────────────────────
info "Checking Python dependencies..."
MISSING=()
while IFS= read -r line; do
  # Strip version specifiers and comments
  pkg=$(echo "$line" | sed 's/[>=<!].*//' | sed 's/#.*//' | xargs)
  [ -z "$pkg" ] && continue
  if ! "$PYTHON" -c "import importlib; importlib.import_module('${pkg//-/_}')" &>/dev/null && \
     ! "$PYTHON" -c "import importlib; importlib.import_module('$pkg')" &>/dev/null; then
    MISSING+=("$pkg")
  fi
done < requirements.txt

if [ ${#MISSING[@]} -gt 0 ]; then
  info "Installing missing packages: ${MISSING[*]}"
  "$PIP" install --upgrade pip -q
  "$PIP" install -r requirements.txt -q
  ok "Dependencies installed"
else
  ok "All dependencies satisfied"
fi

# ── 4. Port availability ─────────────────────────────────────────────────────
info "Checking ports 5000 and 8765..."
for PORT in 5000 8765; do
  if lsof -iTCP:"$PORT" -sTCP:LISTEN &>/dev/null; then
    fail "Port $PORT is already in use. Free it and re-run (lsof -i :$PORT)."
  fi
done
ok "Ports 5000 and 8765 are free"

# ── 5. Template / static files ───────────────────────────────────────────────
info "Checking required files..."
for f in server.py requirements.txt templates/index.html static/style.css static/app.js; do
  [ -f "$SCRIPT_DIR/$f" ] || fail "Missing file: $f"
done
ok "All required files present"

# ── Launch (with restart loop) ────────────────────────────────────────────────
echo ""
echo "$SEP"
echo "  All checks passed. Starting server..."
echo "  Dashboard → http://$(hostname -I 2>/dev/null | awk '{print $1}' || echo localhost):5000"
echo "  Camera WS → ws://0.0.0.0:8765"
echo "  Press Ctrl+C to stop  |  ./start.sh stop  to stop from another terminal"
echo "$SEP"
echo ""

# Write our own PID so 'stop' can find us
echo $$ > "$PIDFILE"

# Clean up PID file and child on exit (Ctrl+C or kill)
_CHILD_PID=""
cleanup() {
  echo ""
  echo "$SEP"
  echo "  [$(date '+%H:%M:%S')] Shutting down server..."
  [ -n "$_CHILD_PID" ] && kill "$_CHILD_PID" 2>/dev/null || true
  rm -f "$PIDFILE"
  echo "  Server stopped."
  echo "$SEP"
  echo ""
  exit 0
}
trap cleanup INT TERM

RESTART_DELAY=5
while true; do
  echo "  [$(date '+%H:%M:%S')] Starting server.py..."
  "$PYTHON" "$SCRIPT_DIR/server.py" --host 0.0.0.0 --port 5000 --ws-port 8765 &
  _CHILD_PID=$!
  wait "$_CHILD_PID" || true
  EXIT_CODE=$?
  echo ""
  echo "$SEP"
  echo "  [$(date '+%H:%M:%S')] Server exited (code $EXIT_CODE)."
  echo "  Restarting in $RESTART_DELAY seconds... (Ctrl+C or './start.sh stop' to quit)"
  echo "$SEP"
  sleep $RESTART_DELAY
done
