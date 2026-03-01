#!/usr/bin/env bash
# pi-display/setup.sh — one-shot setup for the display Pi
set -euo pipefail

echo "==> Installing system dependencies..."
sudo apt update
sudo apt install -y chromium-browser unclutter xorg openbox

echo "==> Making kiosk.sh executable..."
chmod +x kiosk.sh

echo "==> Disabling screen blanking in ~/.config/openbox/autostart..."
mkdir -p ~/.config/openbox
grep -qxF 'xset s off'     ~/.config/openbox/autostart 2>/dev/null || echo 'xset s off'     >> ~/.config/openbox/autostart
grep -qxF 'xset -dpms'     ~/.config/openbox/autostart 2>/dev/null || echo 'xset -dpms'     >> ~/.config/openbox/autostart
grep -qxF 'xset s noblank' ~/.config/openbox/autostart 2>/dev/null || echo 'xset s noblank' >> ~/.config/openbox/autostart

echo ""
echo "✓ Setup complete. No Python venv needed — only system packages used."
echo ""
echo "  Run the kiosk with:"
echo "    ./kiosk.sh --server http://10.0.0.8:5000"
