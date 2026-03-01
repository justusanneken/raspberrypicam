#!/usr/bin/env bash
# pi-camera/setup.sh — one-shot setup for the camera Pi
set -euo pipefail

echo "==> Installing system dependencies..."
sudo apt update
sudo apt install -y python3-picamera2 python3-pip python3-venv

echo "==> Creating virtual environment (with system-site-packages for picamera2)..."
python3 -m venv .venv --system-site-packages

echo "==> Installing Python dependencies..."
.venv/bin/pip install --upgrade pip
.venv/bin/pip install -r requirements.txt

echo ""
echo "✓ Setup complete."
echo ""
echo "  Run the streamer with:"
echo "    source .venv/bin/activate"
echo "    python stream.py --server ws://10.0.0.8:8765"
