#!/usr/bin/env bash
# pi-display/start.sh — preflight check, auto-install, then launch kiosk
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

SEP="─────────────────────────────────────────"

ok()   { echo "  [✓] $*"; }
info() { echo "  [→] $*"; }
warn() { echo "  [!] $*"; }
fail() { echo "  [✗] $*"; exit 1; }

SERVER_URL="${1:-http://10.0.0.8:5000}"

echo ""
echo "$SEP"
echo "  CAM Stream — Display Pi Preflight"
echo "$SEP"

# ── 1. Chromium ───────────────────────────────────────────────────────────────
info "Checking Chromium..."
if ! command -v chromium-browser &>/dev/null && ! command -v chromium &>/dev/null; then
  info "Chromium not found — installing..."
  sudo apt update -q
  sudo apt install -y chromium-browser || fail "Could not install chromium-browser"
fi
ok "Chromium available"

# ── 2. unclutter ─────────────────────────────────────────────────────────────
info "Checking unclutter (cursor hider)..."
if ! command -v unclutter &>/dev/null; then
  info "unclutter not found — installing..."
  sudo apt install -y unclutter || warn "Could not install unclutter — cursor will remain visible"
else
  ok "unclutter available"
fi

# ── 3. DISPLAY env ────────────────────────────────────────────────────────────
info "Checking X display..."
export DISPLAY="${DISPLAY:-:0}"
if ! xset q &>/dev/null; then
  fail "No X display available at $DISPLAY. Make sure the desktop has started."
fi
ok "X display active ($DISPLAY)"

# ── 4. Server reachability ───────────────────────────────────────────────────
HOST=$(echo "$SERVER_URL" | sed 's|http://||' | cut -d: -f1)
PORT=$(echo "$SERVER_URL" | sed 's|http://||' | cut -d: -f2)
info "Checking server reachability ($HOST:$PORT)..."
if ! nc -zw3 "$HOST" "$PORT" &>/dev/null; then
  warn "Cannot reach $HOST:$PORT — server may not be running yet. Starting anyway."
else
  ok "Server reachable at $HOST:$PORT"
fi

# ── 5. Screen blanking ────────────────────────────────────────────────────────
info "Disabling screen blanking..."
xset s off     2>/dev/null || true
xset -dpms     2>/dev/null || true
xset s noblank 2>/dev/null || true
ok "Screen blanking disabled"

# ── 6. script permissions ─────────────────────────────────────────────────────
chmod +x "$SCRIPT_DIR/kiosk.sh"

# ── Launch ────────────────────────────────────────────────────────────────────
echo ""
echo "$SEP"
echo "  All checks passed. Starting kiosk → $SERVER_URL"
echo "$SEP"
echo ""

exec "$SCRIPT_DIR/kiosk.sh" --server "$SERVER_URL"
