#!/usr/bin/env bash
# pi-display/kiosk.sh
# Convenience wrapper — sets up the environment then runs display.py.
# Can be called directly or used as the ExecStart in a systemd unit.
#
# Usage:
#   chmod +x kiosk.sh
#   ./kiosk.sh --server http://192.168.1.100:5000

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export DISPLAY=":0"
export XAUTHORITY="/home/${USER}/.Xauthority"

# Disable screen blanking and power management for the X session
xset s off       2>/dev/null || true
xset -dpms       2>/dev/null || true
xset s noblank   2>/dev/null || true

exec python3 "${SCRIPT_DIR}/display.py" "$@"
