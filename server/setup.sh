#!/usr/bin/env bash
# server/setup.sh — one-shot setup for the relay server
set -euo pipefail

echo "==> Creating virtual environment..."
python3 -m venv .venv

echo "==> Installing Python dependencies..."
.venv/bin/pip install --upgrade pip
.venv/bin/pip install -r requirements.txt

echo ""
echo "✓ Setup complete."
echo ""
echo "  Run the server with:"
echo "    source .venv/bin/activate"
echo "    python server.py --host 0.0.0.0 --port 5000 --ws-port 8765"
