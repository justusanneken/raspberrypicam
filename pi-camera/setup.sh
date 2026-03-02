#!/usr/bin/env bash
# pi-camera/setup.sh
# One-shot setup for Raspberry Pi 5 + Camera Module v2 running Bookworm.
set -euo pipefail

echo "==> Updating package lists..."
sudo apt update -q

echo "==> Installing system packages..."
# python3-picamera2 must come from apt on Bookworm (not pip)
# python3-opencv ships a Bookworm-optimised build with NEON/SIMD
sudo apt install -y \
  python3-picamera2 \
  python3-opencv \
  python3-pip \
  python3-venv \
  libcamera-apps \
  libcamera-tools

echo "==> Creating virtual environment (system-site-packages exposes picamera2 + cv2)..."
python3 -m venv .venv --system-site-packages

echo "==> Installing remaining Python dependencies..."
.venv/bin/python -m pip install --upgrade pip -q
.venv/bin/python -m pip install -r requirements.txt -q

echo ""
echo "Setup complete."
echo ""
echo "  Run with:"
echo "    ./start.sh"
echo "  or:"
echo "    ./start.sh ws://10.0.0.8:8765"
