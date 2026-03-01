#!/usr/bin/env bash
# server/start.sh — preflight check, auto-install, then launch the server
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

# ── Launch ────────────────────────────────────────────────────────────────────
echo ""
echo "$SEP"
echo "  All checks passed. Starting server..."
echo "  Dashboard → http://localhost:5000"
echo "  Camera WS → ws://0.0.0.0:8765"
echo "$SEP"
echo ""

exec "$PYTHON" "$SCRIPT_DIR/server.py" --host 0.0.0.0 --port 5000 --ws-port 8765
